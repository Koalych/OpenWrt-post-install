#!/bin/sh
netshift_install() {
    log "Установка Netshift"
    refresh_package_index || return 1
    run_remote_installer https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh || return 1
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
}
