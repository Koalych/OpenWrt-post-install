#!/bin/sh
# Проверка установки AdGuardHome
agh_installed() { [ -x /opt/AdGuardHome/AdGuardHome ]; }

# Добавляет элемент в начало upstream_dns (повторный запуск безопасен)
agh_add_upstream() {
    _yaml=/opt/AdGuardHome/AdGuardHome.yaml
    [ -f "$_yaml" ] || return 1
    grep -qF "$1" "$_yaml" && return 0
    service AdGuardHome stop
    awk -v line="    - $1" '{ print } /^  upstream_dns:$/ { print line }' "$_yaml" > "$_yaml.new" \
        && mv "$_yaml.new" "$_yaml"
    service AdGuardHome start
}

# Steam-домены в AGH уходят на DNS OpenClash
agh_add_steam_upstream() {
    _port=$(uci -q get openclash.config.dns_port)
    _up="[/"
    for _d in $STEAM_DOMAINS; do _up="${_up}${_d}/"; done
    _up="${_up}]127.0.0.1:${_port:-7874}"
    agh_add_upstream "'$_up'"
}

# Домены Steam, для которых создаются правила OpenClash и отдельный DNS upstream в AGH.
STEAM_DOMAINS="deploy.static.akamaitechnologies.com steampowered.com steamstatic.com steamserver.net steam-api.com steam.tv steamcommunity-a.akamaihd.net steamcommunity.com steamcontent.com"

_yaml=/opt/AdGuardHome/AdGuardHome.yaml
# yaml_replace_list ФАЙЛ КЛЮЧ ЭЛЕМЕНТ...
# Заменяет список под ключом первого уровня секции dns (отступ 2 пробела,
# элементы с отступом 4). Элементы нужно передавать сразу в виде yaml-строк,
# то есть спецсимволы заранее в кавычках: "'[/lan/]127.0.0.1:54'".
# Элементы передаются в awk через разделитель | (в самих элементах его быть не должно).
yaml_replace_list() {
    _f=$1; _k=$2; shift 2
    _items=""
    for _i in "$@"; do _items="${_items}${_items:+|}${_i}"; done
    awk -v key="$_k" -v items="$_items" '
        BEGIN { n = split(items, arr, "|") }
        skip && /^    - / { next }
        { skip = 0 }
        $0 ~ ("^  " key ":") {
            print "  " key ":"
            for (i = 1; i <= n; i++) print "    - " arr[i]
            skip = 1
            next
        }
        { print }
    ' "$_f" > "$_f.new" && mv "$_f.new" "$_f"
}

# yaml_set_scalar ФАЙЛ КЛЮЧ ЗНАЧЕНИЕ: меняет скаляр первого уровня секции dns (отступ 2)
yaml_set_scalar() {
    sed -i "s|^  $2: .*|  $2: $3|" "$1"
}

# DNS: AdGuard Home на :53 (все интерфейсы), dnsmasq на :54 (DHCP + локальные имена)
# Устанавливает AGH и переносит локальный dnsmasq на порт 54.
# Клиенты продолжают обращаться к роутеру на :53, где после мастера будет слушать AGH.
agh_install() {
    ask_yn "Установить AdGuard Home (DNS на :53, dnsmasq переедет на :54)?" || return 0
    refresh_package_index || return 1
    pkg_installed curl || pkg_add curl || return 1

    # 1. Скачиваем и ставим AGH, пока системный DNS ещё жив
    curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

    agh_installed || { warn "AdGuardHome не установился"; return 1; }

    # 2. dnsmasq -> :54, клиентам по DHCP отдаём адрес роутера как DNS (опция 6)
    uci set dhcp.@dnsmasq[0].port='54'
    uci -q delete dhcp.lan.dhcp_option
    uci add_list dhcp.lan.dhcp_option="6,$(lan_ip)"
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    # AGH стартует сразу после установки (мастер на :3000): перезапускаем его
    # уже после переноса dnsmasq, чтобы порт 53 был свободен
    /opt/AdGuardHome/AdGuardHome -s restart

    # 3. Первичная настройка AGH через мастер
    log "Первичная настройка AdGuard Home"
    echo "Открой http://$(lan_ip):3000"
    echo "В мастере:"
    echo "Интерфейс веб-панели: все (или $(lan_ip)), порт 8080;"
    echo "DNS-сервер: ВСЕ интерфейсы, порт 53."
    while true; do
        printf 'AdGuard Home настроен? (y/N): '
        read -r _ans || exit 1
        case "$_ans" in y|Y) break ;; *) echo "Жду. Введи y, когда закончишь." ;; esac
    done

    # 4. Upstream, bootstrap, PTR и локальные имена через dnsmasq на :54
    if [ -f "$_yaml" ]; then
        service AdGuardHome stop
        yaml_replace_list "$_yaml" upstream_dns \
            https://dns.google/dns-query \
            https://cloudflare-dns.com/dns-query \
            https://dns.quad9.net/dns-query \
            "'[/lan/]127.0.0.1:54'" \
            "'[//]127.0.0.1:54'"
        yaml_replace_list "$_yaml" bootstrap_dns \
            8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9
        yaml_replace_list "$_yaml" local_ptr_upstreams 127.0.0.1:54
        yaml_set_scalar "$_yaml" upstream_mode parallel
        yaml_set_scalar "$_yaml" cache_optimistic true
        sed -i 's|use_private_ptr_resolvers: false|use_private_ptr_resolvers: true|' "$_yaml"
        service AdGuardHome enable
        service AdGuardHome start
    else
        warn "Не найден $_yaml, PTR придётся настроить вручную."
    fi

    ensure_connectivity
    log_done "Свободное место: $(get_free_space) MB"
}
