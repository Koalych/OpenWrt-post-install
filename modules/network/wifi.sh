#!/bin/sh
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
