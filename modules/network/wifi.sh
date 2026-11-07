#!/bin/sh
# Настраивает одинаково все найденные Wi-Fi точки доступа.
# Выполнять по кабелю: смена wpad и перезагрузка Wi-Fi могут оборвать беспроводное соединение.
step_wifi() {
    log "Wi-Fi"

    # Ищем существующие радиомодули и связанные с ними точки доступа.
    # Секции могут называться не только radio0/default_radio0.
    _wifi_radios=$(uci show wireless 2>/dev/null | awk -F= '$2 == "wifi-device" { section=$1; sub(/^wireless\./, "", section); print section }')
    _wifi_ifaces=$(uci show wireless 2>/dev/null | awk -F= '$2 == "wifi-iface" { section=$1; sub(/^wireless\./, "", section); print section }')
    _wifi_pairs=
    for _r in $_wifi_radios; do
        for _iface in $_wifi_ifaces; do
            _iface_device=$(uci -q get "wireless.$_iface.device") || continue
            _iface_mode=$(uci -q get "wireless.$_iface.mode")
            [ "$_iface_device" = "$_r" ] && [ "$_iface_mode" = "ap" ] || continue
            _wifi_pairs="$_wifi_pairs $_r|$_iface"
        done
    done

    if [ -z "$_wifi_pairs" ]; then
        warn "Радиомодули Wi-Fi с точками доступа не найдены, настройку пропускаю"
        return 0
    fi

    refresh_package_index || return 1

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

    # Один SSID и пароль для каждой найденной точки доступа. Каналы не меняю.
    for _pair in $_wifi_pairs; do
        _r=${_pair%%|*}
        _iface=${_pair#*|}
        uci set "wireless.$_r.country=$WIFI_CC"
        # На свежей системе disabled может находиться на radio или wifi-iface.
        uci -q delete "wireless.$_r.disabled"
        uci -q delete "wireless.$_iface.disabled"
        uci set "wireless.$_iface.ssid=$_ssid"
        uci set "wireless.$_iface.encryption=$_enc"
        uci set "wireless.$_iface.key=$_key"
        if pkg_installed wpad-mbedtls; then
            uci set "wireless.$_iface.ieee80211k=1"
            uci set "wireless.$_iface.bss_transition=1"
        fi
    done
    uci commit wireless
    log "Поднимаю Wi-Fi"
    wifi reload
    sleep 5
    wifi up
}
