#!/bin/sh
# Настраивает Tailscale как отдельную firewall-зону, разрешает маршрутизацию
# между tailscale0, LAN и WAN, а также объявляет LAN-подсеть и exit node.
step_tailscale() {
    ask_yn "Установить Tailscale?" || return 0
    refresh_package_index || return 1
    pkg_add tailscale luci-app-tailscale-community || return 1

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
