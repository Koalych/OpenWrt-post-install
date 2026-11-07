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
#!/bin/sh
# Файл перезаписывается целиком при каждом вызове.
openclash_write_rules() {
    {
        echo "rules:"
        for _d in $STEAM_DOMAINS; do echo "- DOMAIN-SUFFIX,$_d,WARP"; done
    } > /etc/openclash/custom/openclash_custom_rules.list
}

openclash_install () {
    log "Установка OpenClash + WARP"
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