#!/bin/sh
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

forkop_install() {
    log "Установка Forkop"
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
}