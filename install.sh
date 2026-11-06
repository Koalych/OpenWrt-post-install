#!/bin/sh
# OpenWrt-post-install
# Цель: чистая OpenWrt 25.12+ (пакетный менеджер apk). Изначально под GL-MT3000.
#
# Структура:
#   1. хелперы
#   2. шаги (step_*): каждый делает одно дело и сам спрашивает подтверждение
#   3. ветки по странам (setup_ru, setup_vn)
#   4. main: порядок вызова
#
# Принципы:
#   - секции uci создаём именованными (uci set x.name=type), а не через
#     `uci add`; исключение функция oc_dns; повторный запуск не плодит дубли;
#   - адрес и подсеть LAN берём из конфига, а не зашиваем;
#   - если LAN-адрес меняется, SSH-сессия обрывается: подключись по новому
#     адресу и запусти скрипт ещё раз;
#   - ошибка в страновой ветке (Forkop/Netshift/OpenClash) останавливает main,
#     чтобы последующие шаги не маскировали неудачную установку.

### ───────────── 1. Хелперы ─────────────

# Заголовок шага: пустая строка сверху и снизу.
# _BLANK=1 значит, что последним был log_done и пустая строка уже стоит снизу;
# тогда следующий log не добавляет свою, и между двумя log остаётся одна строка.
_BLANK=
log()      { [ -n "$_BLANK" ] || printf '\n'; printf '==> %s\n\n' "$*"; _BLANK=; }
log_done() { log "$@"; _BLANK=1; }   # последний log шага
warn()     { _BLANK=; printf '!! %s\n' "$*"; }

ESC=$(printf '\033')

# Убирает маркеры bracketed paste (ESC[200~ и ESC[201~), которые терминал
# добавляет при вставке: без этого они попадали бы в ссылки и пароли.
clean_paste() {
    printf '%s' "$1" | sed "s/${ESC}\[20[01]~//g"
}

# Возвращает свободное место в /overlay в MiB (округление вниз).
# Значение вычисляется при каждом вызове, поэтому учитывает уже установленные пакеты.
get_free_space() {
    df -k /overlay | awk 'NR==2 {print int($4 / 1024)}'
}

# ask_yn "Вопрос": код возврата 0, если ответили y/yes
ask_yn() {
    _BLANK=
    printf '%s [y/N]: ' "$1"
    read -r _ans
    _ans=$(clean_paste "$_ans")
    case "$_ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ask "Вопрос" "по умолчанию": ответ кладёт в $ANSWER
ask() {
    _BLANK=
    printf '%s [%s]: ' "$1" "$2"
    read -r ANSWER
    ANSWER=$(clean_paste "$ANSWER")
    ANSWER="${ANSWER:-$2}"
}

# Проверка наличия пакета и короткая обёртка над apk add.
pkg_installed() { apk info -e "$1" >/dev/null 2>&1; }
pkg_add()       { apk add "$@"; }

# Убирает маску, если UCI хранит адрес в формате 192.168.50.1/24.
# 192.168.50.1/24 -> 192.168.50.1
lan_ip() {
    _ip=$(uci -q get network.lan.ipaddr)
    echo "${_ip%%/*}"
}

# Возвращает подсеть LAN для объявления в Tailscale.
# Допущение: LAN это /24 (192.168.50.1 -> 192.168.50.0/24).
# Если вручную настроить другую маску, результат будет неверным.
lan_subnet() {
    _ip=$(lan_ip)
    echo "${_ip%.*}.0/24"
}

# Проверяет синтаксис IPv4 и диапазон октетов 0–255.
# Не проверяет, является ли адрес сетевым, широковещательным или допустимым для LAN.
valid_ip() {
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++)
                if ($i !~ /^[0-9]+$/ || $i > 255 || $i == "")
                    exit 1
        }
    ' <<EOF
$1
EOF
}

# Проверка установки AdGuardHome
agh_installed() { [ -x /opt/AdGuardHome/AdGuardHome ]; }

# Создаёт одну DNS-запись OpenClash.
# Аргументы: группа (nameserver/default), тип (udp/https) и адрес сервера.
# Здесь используется uci add, поскольку список dns_servers намеренно состоит
# из нескольких однотипных анонимных секций.
oc_dns() {
    _id=$(uci add openclash dns_servers)
    uci set openclash.$_id.enabled='1'
    uci set openclash.$_id.group="$1"
    uci set openclash.$_id.type="$2"
    uci set openclash.$_id.ip="$3"
    uci set openclash.$_id.interface='Disable'
    uci set openclash.$_id.direct_nameserver='1'
    uci set openclash.$_id.node_resolve='1'
    uci set openclash.$_id.disable_ipv4='0'
    uci set openclash.$_id.disable_ipv6='0'
    [ "$1" = nameserver ] && uci set openclash.$_id.specific_group='Disable' || return 0
}

# Полностью пересобирает список DNS-серверов OpenClash, чтобы повторный запуск
# не оставлял старые или дублирующиеся записи.
openclash_dns() {
    while uci -q delete openclash.@dns_servers[0]; do :; done

    if agh_installed; then
        oc_dns nameserver udp "$(lan_ip)"
    else
        oc_dns nameserver https dns.google/dns-query
        oc_dns nameserver https cloudflare-dns.com/dns-query
        oc_dns default udp 8.8.8.8     # только чтобы найти адреса DoH-серверов
        oc_dns default udp 1.1.1.1
    fi
}

# Очищает скачанные/пользовательские данные OpenClash и применяет базовые настройки.
# ВНИМАНИЕ: содержимое перечисленных каталогов удаляется без резервной копии.
openclash_configure() {
    rm -f /etc/openclash/custom/*
    rm -f /etc/openclash/GeoSite.dat
    rm -f /etc/openclash/Country.mmdb
    rm -f /etc/openclash/overwrite/*
    rm -f /etc/openclash/china_*
    rm -f /etc/openclash/rule_provider/*
    rm -rf /usr/share/openclash/backup/*
    rm -f /usr/share/openclash/res/*
    rm -rf /usr/share/openclash/ui/metacubexd

    if agh_installed; then
        uci set openclash.config.enable_redirect_dns='0'    # AGH сам отправляет Steam в OpenClash
        uci set openclash.config.redirect_dns='0'
    else
        uci set openclash.config.enable_redirect_dns='1'
        uci set openclash.config.redirect_dns='1'
    fi
    uci set openclash.config.enable_custom_dns='1'
    uci set openclash.config.filter_aaaa_dns='1'
    uci set openclash.config.cachesize_dns='1'
    uci set openclash.config.store_fakeip='1'
    uci set openclash.config.enable_custom_clash_rules='1'
    uci set openclash.config.fakeip_range='198.18.0.1/16'
    uci set openclash.config.enable_meta_sniffer='1'
    uci set openclash.config.enable_meta_sniffer_pure_ip='1'
    uci set openclash.config.disable_udp_quic='0'
    uci set openclash.config.disable_quic_go_gso='0'
    uci set openclash.config.default_dashboard='zashboard'
    uci set openclash.config.router_self_proxy='0'

    openclash_dns

    # После очистки и настройки DNS устанавливаем совместимое ядро OpenClash.
    log "Устанавливаю ядро"
    sh /usr/share/openclash/openclash_core.sh || return 1

    uci commit openclash
}

# Формирует пользовательский список правил: перечисленные домены направляются в WARP.
# Файл перезаписывается целиком при каждом вызове.
openclash_write_rules() {
    {
        echo "rules:"
        for _d in $STEAM_DOMAINS; do echo "- DOMAIN-SUFFIX,$_d,WARP"; done
    } > /etc/openclash/custom/openclash_custom_rules.list
}

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

# Создание случайных имен для секций
rand_id() { tr -dc 'a-f0-9' </dev/urandom | head -c 6; }

# Создание секций Forkop
forkop_add_link() {
    # Берём первую существующую секцию, иначе создаём
    _sec=$(uci -q show "forkop.@section[0]" | sed -n '1s/^forkop\.\([^=]*\)=.*/\1/p')
    if [ -z "$_sec" ]; then
        _sec="section_$(rand_id)"
        uci set "forkop.$_sec=section"
        uci set forkop.$_sec.label='MAIN'
        uci set forkop.$_sec.enabled='1'
        uci set forkop.$_sec.action='connection'
        uci add_list forkop.$_sec.community_lists='ru_blocked_all'
    fi

    # Чистим старые ссылки и подписки, чтобы не плодить дубли при повторном запуске
    for _t in subscription_url connection_link; do
        while uci -q delete "forkop.@${_t}[0]"; do :; done
    done

    if [ "$LINK_KIND" = subscription ]; then
        _id="sub_$(rand_id)"
        uci set "forkop.$_id=subscription_url"
        uci set "forkop.$_id.section=$_sec"
        uci set "forkop.$_id.url=$LINK"
        uci set "forkop.$_id.tag=sub1"
        uci set "forkop.$_id.server_filter_mode=all"
        uci set "forkop.$_id.subscription_update_enabled=1"
        uci set "forkop.$_id.subscription_update_interval=1h"
        uci set "forkop.$_id.download_via_proxy_enabled=0"
    else
        _id="link_$(rand_id)"
        uci set "forkop.$_id=connection_link"
        uci set "forkop.$_id.section=$_sec"
        uci set "forkop.$_id.uri=$LINK"
        uci set "forkop.$_id.name=MAIN"
        uci set "forkop.$_id.order=0"
    fi
}

# Результат: LINK_KIND (url|subscription) и LINK. Возврат 1 — пользователь пропустил.
ask_link() {
    while true; do
        ask "Добавить ссылку на сервер(1) или подписку(2) (1/2/N)?" "N"
        case "$ANSWER" in
            1) _kind=url;          _q="Вставь ссылку на сервер:";   _def="vless://" ;;
            2) _kind=subscription; _q="Вставь ссылку на подписку:"; _def="https://" ;;
            N|n) return 1 ;;
            *) warn "Некорректный ввод"; continue ;;
        esac

        ask "$_q" "$_def"
        case "$ANSWER" in
            *[![:print:]]*|*' '*) warn "Недопустимые символы в ссылке"; continue ;;
        esac

        if [ "$_kind" = url ]; then
            case "$ANSWER" in
                vless://?*|vmess://?*|ss://?*|trojan://?*|socks4://?*|socks5://?*|hy2://?*|hysteria2://?*|tuic://?*|anytls://?*|naive+https://?*|https://?*) ;;
                *) warn "Неподдерживаемый формат ссылки"; continue ;;
            esac
        else
            case "$ANSWER" in
                https://?*) ;;
                *) warn "Неподдерживаемый формат подписки"; continue ;;
            esac
        fi

        LINK_KIND=$_kind
        LINK=$ANSWER
        return 0
    done
}

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

# OpenClash требует dnsmasq-full вместо dnsmasq (взаимоисключающие, как wpad).
# На время замены локального DNS нет, поэтому временно берём публичные резолверы.
ensure_dnsmasq_full() {
    # Если уже установлен полный вариант, ничего не меняем.
    pkg_installed dnsmasq-full && return 0
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf
    if pkg_installed dnsmasq; then
        apk del dnsmasq || return 1
    fi
    pkg_add dnsmasq-full
}

# Промежуточный шаг после AGH: проверяем, что список пакетов снова доступен.
# Сразу после перезапуска AGH его DoH-upstream может быть ещё не готов.
ensure_connectivity() {
    # Несколько попыток дают AGH время поднять DoH-upstream после перезапуска.
    log "Проверка соединения"
    for _t in 1 2 3 4 5; do
        apk update >/dev/null 2>&1 && return 0
        sleep 3
    done
    warn "DNS не отвечает, временно беру 1.1.1.1 и 8.8.8.8 (до перезапуска dnsmasq или перезагрузки)"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf
    apk update || { warn "Связи нет, дальше не продолжаю"; exit 1; }
}

# Русские переводы LuCI: по одному пакету на каждый установленный luci-app-*.
# Ставим по одному, потому что apk работает транзакцией: если для какого-то
# приложения перевода нет, одна общая команда упала бы целиком.
install_luci_i18n() {
    # Список приложений считывается после установки всех выбранных компонентов.
    ask_yn "Установить русскую локализацию LuCI?" || return 0
    pkg_installed luci-i18n-base-ru || pkg_add luci-i18n-base-ru
    for _a in $(apk list -I 2>/dev/null | grep '^luci-app-' | sed -E 's/ .*//; s/-[0-9].*//'); do
        apk add "luci-i18n-${_a#luci-app-}-ru" >/dev/null 2>&1 || :
    done
    if pkg_installed luci-mod-dashboard; then
        pkg_add luci-i18n-dashboard-ru
    fi

    log_done "Свободное место: $(get_free_space) MB"
}

# Блоки итоговой сводки (*_final) выводятся из step_final. Формат у всех один:
# разделитель в начале, пустая строка в конце, без пустой строки перед разделителем.
# Блок молча пропускается, если его компонент не установлен.
# Подведение итогов работы скрипта и напоминание о ручных действиях
forkop_final() {
    pkg_installed forkop || return 0
    cat <<'EOF'
————————————————————————————————————————————————————
Forkop: OK

Не забудь:
1. Создай секцию и введи URL сервера или подписки, если не указывал в процессе установки.
2. В условия секции подставь свои домены или выбери списки сообщества.
3. После сохранения перейди во вкладку статус и включи Forkop с автостартом.

EOF
}

# Напоминание о ручных действиях после установки Netshift
netshift_final() {
    pkg_installed netshift || return 0
    cat <<'EOF'
————————————————————————————————————————————————————
Netshift: OK

Не забудь:
1. Введи URL сервера или подписки, если не указывал в процессе установки.
2. В маршрутизации секции подставь свои домены или выбери списки сообщества.
3. После сохранения перейди во вкладку диагностики и включи Netshift с автостартом.

EOF
}

# Напоминание про авторизацию Tailscale и настройки в консоли администратора
tailscale_final() {
    pkg_installed tailscale || return 0
    cat <<'EOF'
————————————————————————————————————————————————————
Tailscale: OK

Не забудь:
1. В LuCI открой раздел Tailscale, войди в аккаунт по ссылке.
2. В админке Tailscale одобри маршрут и exit node у роутера.
3. Отключи key expiry для роутера.
4. DNS -> Nameservers: tailscale-адрес роутера, включить Override.

EOF
}

# Напоминание про конфиг WARP для OpenClash (добавляется вручную)
openclash_final() {
    pkg_installed luci-app-openclash || return 0
    cat <<'EOF'
————————————————————————————————————————————————————
OpenClash: OK

Не забудь:
1. Для работы OpenClash необходим конфиг WARP в формате yaml
Подсказка: Загрузи свой или возьми здесь https://warp-generation.github.io или https://mirror.llimonix.pw (Clash MASQUE)
2. В LuCI открой раздел OpenClash, добавь конфиг через панель на странице Overviews
3. Во вкладке Config Manage убери внизу секцию rules и нажми Apply Settings
4. Запусти сервис

EOF
}

# Адрес веб-панели AdGuard Home и необязательные настройки после мастера
adguardhome_final() {
    agh_installed || return 0
    cat <<EOF
————————————————————————————————————————————————————
AdGuardHome: OK
Адрес веб-панели: http://$(lan_ip):8080

Не забудь:
1. Проверь Upstream и Bootstrap DNS сервера в настройках DNS
2. (Опционально) Измени "Черные списки DNS" во вкладке "Фильтры"
3. (Опционально) Измени частоту ротации журнала запросов

EOF
}

# Как зайти на роутер: LuCI, SSH и имя Wi-Fi. Выводится первым блоком сводки.
# Пароль Wi-Fi намеренно не печатается.
system_final() {
    _host=$(uci -q get system.@system[0].hostname)
    cat <<EOF
————————————————————————————————————————————————————
Система: OK
Веб-панель LuCI: http://$(lan_ip) (или http://${_host:-OpenWrt}.lan)
SSH: ssh root@$(lan_ip)
EOF
    [ -z "$_ssid" ] || echo "Wi-Fi: $_ssid"
    echo
}

### ───────────── 2. Шаги ─────────────

# Проверяет минимальные условия запуска и подтверждает целевое устройство.
step_preflight() {
    [ -x /usr/bin/apk ] || {
        warn "Скрипт рассчитан на OpenWrt 25.12+ (нужен apk). Читай README."
        exit 1
    }
    ask_yn "Скрипт ориентирован на GL-MT3000; на других устройствах возможны отличия. Продолжить?" || exit 0
}

# Смена LAN-адреса. Идёт первым шагом: SSH-сессия оборвётся, после этого
# нужно подключиться по новому адресу и запустить скрипт ещё раз.
# Дефолт 192.168.50.1: не пересекается с типичными модемами провайдеров (192.168.1.1).
step_lan() {
    _cur=$(lan_ip)
    ask "LAN-адрес роутера" "$_cur"
    while ! valid_ip "$ANSWER"; do
        warn "Некорректный IPv4-адрес"
        ask "LAN-адрес роутера" "$_cur"
    done
    [ "$ANSWER" = "$_cur" ] && return 0

    uci set network.lan.ipaddr="$ANSWER/24"
    uci -q delete network.lan.netmask
    uci commit network
    echo "LAN-адрес изменён на $ANSWER."
    echo "Подключись заново (ssh root@$ANSWER) и запусти скрипт ещё раз."
    ( sleep 2; /etc/init.d/network restart ) >/dev/null 2>&1 &
    exit 0
}

# Выбор страны определяет часовой пояс, код страны Wi-Fi и набор обходов
# Сохраняет выбранные параметры страны в глобальные переменные для следующих шагов.
step_country() {
    ask "Страна: (1) Россия / (2) Вьетнам / (3) другая" "1"
    case "$ANSWER" in
        1) COUNTRY=ru;    WIFI_CC=RU; TZ_NAME='Europe/Moscow';    TZ_POSIX='MSK-3' ;;
        2) COUNTRY=vn;    WIFI_CC=VN; TZ_NAME='Asia/Ho_Chi_Minh'; TZ_POSIX='ICT-7' ;;
        3) COUNTRY=other; TZ_NAME='UTC'; TZ_POSIX='UTC0'
           ask "Двухбуквенный код страны для Wi-Fi (например US)" "US"
           WIFI_CC="$ANSWER" ;;
        *) COUNTRY=ru;    WIFI_CC=00; TZ_NAME='UTC'; TZ_POSIX='UTC0' ;;
    esac
}

# Базовые инструменты, необходимые независимо от выбранной страны и дополнительных функций.
step_base_packages() {
    log "Обновление списка пакетов"
    apk update || return 1

    log "Установка основных пакетов"
    # Переводы приложений ставит install_luci_i18n в конце, когда все luci-app-* на месте
    pkg_add curl openssh-sftp-server luci-base || return 1
    log_done "Завершено. Свободное место: $(get_free_space) MB"
}

# Необязательный набор пакетов автора; отказ не влияет на дальнейшую установку.
step_personal_packages() {
    if ask_yn "Установить пакеты которые использует автор?
Список пакетов: bash, lsd, ripgrep, ss, btop, net-tools-netstat, luci-mod-dashboard, ncdu"; then
        pkg_add bash lsd ripgrep ss btop net-tools-netstat luci-mod-dashboard ncdu
        log_done "Завершено. Свободное место: $(get_free_space) MB"
    fi
}

# Позволяет передать произвольный список имён пакетов в apk add.
# Ввод разделяется shell по пробелам; не предназначен для сложных имён с пробелами.
step_additional_packages() {
    if ask_yn "Нужны дополнительные пакеты?"; then
        printf 'Имена пакетов через пробел: '
        read -r _pk
        [ -n "$_pk" ] && pkg_add $_pk
        log_done "Завершено. Свободное место: $(get_free_space) MB"
    fi
}

# Настраивает интерфейс LuCI, hostname, часовой пояс и пароль root.
step_system() {
    log "LuCI и система"
    uci set luci.main.lang='ru'
    ask "Тема LuCI: (1) светлая / (2) тёмная" "2"
    case "$ANSWER" in
        1) uci set luci.main.mediaurlbase='/luci-static/bootstrap-light' ;;
        *) uci set luci.main.mediaurlbase='/luci-static/bootstrap-dark' ;;
    esac
    uci set luci.main.tablefilters='1'
    uci set attendedsysupgrade.client.login_check_for_upgrades='1'

    ask "Hostname" "OpenWRT"
    uci set system.@system[0].hostname="$ANSWER"
    uci set system.@system[0].timezone="$TZ_POSIX"
    uci set system.@system[0].zonename="$TZ_NAME"
    uci set system.@system[0].clock_hourcycle='h23'
    uci set system.@system[0].clock_timestyle='1'
    uci commit

    if ask_yn "Установить пароль root?"; then
        until passwd; do warn "Ошибка выполнения, повтори"; done
    fi
}

# Настраивает оба штатных радио GL-MT3000 одинаково.
# Выполнять по кабелю: смена wpad и перезагрузка Wi-Fi могут оборвать беспроводное соединение.
step_wifi() {
    log "Wi-Fi"

    # Полный wpad нужен для 802.11k/v (band steering) и WPA3.
    # ВНИМАНИЕ: на время замены Wi-Fi пропадает, запускать по кабелю.
    if pkg_installed wpad-basic-mbedtls && ask_yn "Заменить wpad-basic-mbedtls на полный wpad-mbedtls?"; then
        apk del wpad-basic-mbedtls && pkg_add wpad-mbedtls || return 1
    fi

    ask "SSID" "OpenWRT"
    _ssid="$ANSWER"
    ask "Шифрование: (1) WPA3 / (2) WPA2+WPA3 mixed / (3) только WPA2" "2"
    case "$ANSWER" in
        1) _enc=sae ;;
        3) _enc=psk2 ;;
        *) _enc=sae-mixed ;;
    esac
    printf 'Пароль Wi-Fi (минимум 8 символов): '
    read -r _key
    _key=$(clean_paste "$_key")
    printf '\n'
    while [ "${#_key}" -lt 8 ] || [ "${#_key}" -gt 63 ]; do
        printf 'Пароль должен содержать от 8 до 63 символов: '
        read -r _key
        _key=$(clean_paste "$_key")
        printf '\n'
    done

    # Один SSID на всех радио. Канал не трогаю (по умолчанию auto).
    for _r in radio0 radio1; do
        uci -q get wireless.$_r >/dev/null || continue
        uci set wireless.$_r.country="$WIFI_CC"
        # на свежей системе флаг disabled стоит на wifi-iface: убираем (на radio тоже, на всякий случай)
        uci -q delete wireless.$_r.disabled
        uci -q delete wireless.default_$_r.disabled
        uci set wireless.default_$_r.ssid="$_ssid"
        uci set wireless.default_$_r.encryption="$_enc"
        uci set wireless.default_$_r.key="$_key"
        if pkg_installed wpad-mbedtls; then
            uci set wireless.default_$_r.ieee80211k='1'
            uci set wireless.default_$_r.bss_transition='1'
        fi
    done
    uci commit wireless
    log "Поднимаю Wi-Fi"
    wifi reload
    sleep 5
    wifi up
}

# Устанавливает поддержку USB-накопителей и, по желанию, Transmission.
# Сам накопитель здесь не размечается и не монтируется.
step_storage() {
    ask_yn "Есть USB-накопитель, планируешь использовать?" || return 0
    pkg_add blockd kmod-fs-vfat kmod-usb-storage-uas kmod-usb2 kmod-usb3 lsblk

    ask "Файловая система накопителя: 1)ext4 2)exfat 3)ntfs N)другая (1/2/3/N)" "N"
    case "$ANSWER" in
        1) pkg_add kmod-fs-ext4 ;;
        2) pkg_add kmod-fs-exfat ;;
        3) pkg_add kmod-fs-ntfs3 ;;
        N|n) ;;
        *) warn "Некорректный ввод" ;;
    esac
    log "Завершено"

    ask_yn "Установить Transmission?" || return 0
    pkg_add luci-i18n-transmission-ru transmission-web
    uci set transmission.@transmission[0].enabled='1'
    uci commit transmission

    log_done "Свободное место: $(get_free_space) MB"
}

# DNS: AdGuard Home на :53 (все интерфейсы), dnsmasq на :54 (DHCP + локальные имена)
# Устанавливает AGH и переносит локальный dnsmasq на порт 54.
# Клиенты продолжают обращаться к роутеру на :53, где после мастера будет слушать AGH.
step_dns() {
    ask_yn "Установить AdGuard Home (DNS на :53, dnsmasq переедет на :54)?" || return 0

    # OpenClash требует dnsmasq-full вместо dnsmasq (то же, что с wpad)
    [ "$COUNTRY" != vn ] || ensure_dnsmasq_full || return 1

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

# Настраивает Tailscale как отдельную firewall-зону, разрешает маршрутизацию
# между tailscale0, LAN и WAN, а также объявляет LAN-подсеть и exit node.
step_tailscale() {
    ask_yn "Установить Tailscale?" || return 0
    pkg_add tailscale luci-app-tailscale-community

    uci set firewall.tailscale=zone
    uci set firewall.tailscale.name='Tailscale'
    uci set firewall.tailscale.input='ACCEPT'
    uci set firewall.tailscale.output='ACCEPT'
    uci set firewall.tailscale.forward='ACCEPT'
    uci set firewall.tailscale.masq='1'
    uci set firewall.tailscale.mtu_fix='1'
    uci -q delete firewall.tailscale.device
    uci add_list firewall.tailscale.device='tailscale0'
    for _d in lan wan; do
        uci set firewall.ts_to_$_d=forwarding
        uci set firewall.ts_to_$_d.src='Tailscale'
        uci set firewall.ts_to_$_d.dest="$_d"
    done
    uci commit firewall

    uci set tailscale.settings.advertise_exit_node='1'
    uci set tailscale.settings.ssh='1'
    uci set tailscale.settings.disable_magic_dns='1'
    uci -q delete tailscale.settings.advertise_routes
    uci add_list tailscale.settings.advertise_routes="$(lan_subnet)"
    uci commit tailscale

    service tailscale enable
    service tailscale start

    log_done "Свободное место: $(get_free_space) MB"
}

# Устанавливает утилиту и LuCI-интерфейс для отправки Wake-on-LAN пакетов.
step_wol() {
    ask_yn "Установить Wake-on-LAN?" || return 0
    pkg_add etherwake luci-app-wol
    log_done "Свободное место: $(get_free_space) MB"
}

### ───────────── 3. Ветки по странам ─────────────

# Россия: выбор и установка одного из двух вариантов обхода блокировок.
# Ошибка установки возвращается в main и останавливает дальнейшее выполнение.
setup_ru() {
    while true; do
        ask "Установить Forkop(1) или Netshift(2) (1/2/N)?" "N"
        case "$ANSWER" in
            1)
                log "Россия: установка Forkop"
                sh <(wget -O - https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh)
                pkg_installed forkop || { warn "Forkop не установился"; return 1; }

                if agh_installed; then
                    yaml_replace_list "$_yaml" bind_hosts "$(lan_ip)" 127.0.0.1
                    /opt/AdGuardHome/AdGuardHome -s restart
                    sleep 5
                fi

                if agh_installed && ask_yn "Использовать AdGuard Home как DNS для Forkop?"; then
                    _dns="$(lan_ip):53"
                else
                    agh_installed && warn "Forkop будет резолвить в обход AGH и его блок-листов"
                    _dns="https://dns.google/dns-query"
                fi

                uci -q delete forkop.settings.dns_server
                uci add_list forkop.settings.dns_server="$_dns"
                uci -q delete forkop.settings.bootstrap_dns_server

                if ask_yn "Bootstrap DNS для Forkop (8.8.8.8, 8.8.4.4)?"; then
                    uci add_list forkop.settings.bootstrap_dns_server='8.8.8.8'
                    uci add_list forkop.settings.bootstrap_dns_server='8.8.4.4'
                fi

                if ask_link; then
                    forkop_add_link
                fi

                uci commit forkop
                forkop enable
                forkop stop
                forkop start
                log_done "Свободное место: $(get_free_space) MB"
                break
                ;;
            2)
                log "Россия: установка Netshift"
                sh <(wget -O - https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh)
                pkg_installed netshift || { warn "Netshift не установился"; return 1; }

                if agh_installed; then
                    yaml_replace_list "$_yaml" bind_hosts "$(lan_ip)" 127.0.0.1
                    /opt/AdGuardHome/AdGuardHome -s restart
                    sleep 5
                fi

                if agh_installed && ask_yn "Использовать AdGuard Home как DNS для Netshift?"; then
                    _dns="$(lan_ip):53"
                    _dns_type="udp"
                    uci set netshift.settings.dont_touch_dhcp='1'
                else
                    agh_installed && warn "Netshift будет резолвить в обход AGH и его блок-листов"
                    _dns="https://dns.google/dns-query"
                    _dns_type="doh"
                fi

                if ip -6 addr show scope global | grep -Eiq 'inet6 [23][0-9a-f:]*/'; then
                    uci set netshift.settings.enable_ipv6='1'
                fi

                uci -q delete netshift.settings.dns_server
                uci -q delete netshift.settings.dns_type
                uci -q delete netshift.settings.bootstrap_dns_server
                uci add_list netshift.settings.dns_server="$_dns"
                uci add_list netshift.settings.dns_type="$_dns_type"

                if ask_yn "Bootstrap DNS для Netshift (8.8.8.8)?"; then
                    uci add_list netshift.settings.bootstrap_dns_server='8.8.8.8'
                fi

                if ask_link; then
                    uci -q delete netshift.main.proxy_string
                    uci -q delete netshift.main.subscription_url
                    uci set netshift.main.proxy_config_type="$LINK_KIND"
                    if [ "$LINK_KIND" = url ]; then
                        uci set netshift.main.proxy_string="$LINK"
                    else
                        uci set netshift.main.subscription_url="$LINK"
                    fi
                fi

                uci commit netshift
                if [ -n "$(uci -q get netshift.main.proxy_string)$(uci -q get netshift.main.subscription_url)" ]; then
                    netshift stop
                    netshift start
                fi
                log_done "Свободное место: $(get_free_space) MB"
                break
                ;;
            N|n)
                return 0
                ;;
            *)
                warn "Некорректный ввод"
                ;;
        esac
    done
}

# Вьетнам: OpenClash + WARP. Пакет загружается напрямую из последнего GitHub Release.
# После установки применяются базовые настройки; конфиг WARP пользователь добавляет вручную.
setup_vn() {
    log "Вьетнам: OpenClash + WARP"
    ask_yn "Установить OpenClash?" || return 0

    ensure_dnsmasq_full || return 1
    pkg_add bash curl ca-bundle ip-full ruby ruby-yaml kmod-tun kmod-inet-diag \
        unzip kmod-nft-tproxy luci-compat luci luci-base

    # Удаляем остатки предыдущей загрузки, чтобы при сетевой ошибке не установить старый APK.
    rm -f /tmp/openclash_version /tmp/openclash.apk

    curl -fsSL --retry 2 https://api.github.com/repos/vernesong/OpenClash/releases/latest -o /tmp/openclash_version
    [ -f "/tmp/openclash_version" ] && download_url=$(cat /tmp/openclash_version | jsonfilter -e '@.assets[*].browser_download_url' | grep '\.apk$') && curl -fsSL --retry 2 "$download_url" -o /tmp/openclash.apk || echo "OpenClash last version get failed"
    [ -f "/tmp/openclash.apk" ] && apk add -q --force-overwrite --clean-protected --allow-untrusted /tmp/openclash.apk || echo "OpenClash download failed"

    pkg_installed luci-app-openclash || { warn "OpenClash не установился"; return 1; }
    openclash_configure

    if ask_yn "Добавить правила для обхода блокировки Steam?"; then
        openclash_write_rules
        if agh_installed; then
            agh_add_steam_upstream
        fi
    fi

    log_done "Свободное место: $(get_free_space) MB"
}

# Скрипты для случайного ASCII MOTD при входе в систему OpenWrt по SSH.
step_banners() {
    if ! ask_yn "Заменить подсказку по apk на баннеры?"; then
        log_done "Установка баннеров пропущена"
        return 0
    fi

    _motd_tmp=$(mktemp /tmp/install-MOTD.XXXXXX) || {
        warn "Не удалось создать временный файл для установщика баннеров"
        return 0
    }

    if ! wget -qO "$_motd_tmp" https://raw.githubusercontent.com/Koalych/OpenWrt-random-MOTD/main/install.sh || [ ! -s "$_motd_tmp" ]; then
        rm -f "$_motd_tmp"
        warn "Не удалось скачать установщик баннеров"
        return 0
    fi

    if ! sh "$_motd_tmp"; then
        rm -f "$_motd_tmp"
        warn "Установщик баннеров завершился с ошибкой"
        return 0
    fi

    rm -f "$_motd_tmp"
    log_done "Баннеры установлены. Свободное место: $(get_free_space) MB"
}

# Восстановление работы слайдера боковой панели GL-MT3000 на OpenWrt
# Проверить работу кнопок при переключении можно командой logread -f
step_button() {
    ask_yn "Восстановить работу слайдера боковой панели GL-MT3000 на OpenWrt?" || return 0
    mkdir -p /etc/hotplug.d/button
    cat > /etc/hotplug.d/button/50-mode-switch << 'EOF'
#!/bin/sh
[ "$BUTTON" = "BTN_0" ] || exit 0

case "$ACTION" in
    pressed)
        logger -t mode-switch "Переключено в положение 1"
        # ваша логика для положения 1
        ;;
    released)
        logger -t mode-switch "Переключено в положение 2"
        # ваша логика для положения 2
        ;;
esac
EOF
chmod +x /etc/hotplug.d/button/50-mode-switch
log_done "Завершено. Задать логику слайдера можно в файле /etc/hotplug.d/button/50-mode-switch"
}

### ───────────── 4. Завершение ─────────────

# Каждый блок сводки начинается с разделителя и заканчивается пустой строкой,
# поэтому в конце помечаем, что пустая строка снизу уже есть.
step_final() {
    log "Итоговая сводка"
    system_final
    adguardhome_final
    forkop_final
    netshift_final
    openclash_final
    tailscale_final
    _BLANK=1
}

# Финальный шаг: предлагает перезагрузку после изменения системных служб и сетевых настроек.
step_finish() {
    log "Готово"
    if ask_yn "Перезагрузить сейчас? (рекомендуется)"; then
        reboot
    else
        echo "Без перезагрузки. Службы могут потребовать ручного перезапуска."
    fi
}

### ───────────── main ─────────────

# Общий порядок установки. Страновая ветка вызывается последней среди основных
# настроек; её ошибка завершает скрипт, а успешное выполнение ведёт к переводам и MOTD.
main() {
    step_preflight
    step_lan
    step_country
    step_base_packages || exit 1
    step_personal_packages
    step_additional_packages
    step_system
    step_wifi || exit 1
    step_storage
    step_dns || exit 1
    step_tailscale
    step_wol
    case "$COUNTRY" in
        ru) setup_ru || exit 1 ;;
        vn) setup_vn || exit 1 ;;
    esac
    install_luci_i18n
    step_banners
    step_button
    step_final
    step_finish
}

main "$@"