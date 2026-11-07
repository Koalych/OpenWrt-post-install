#!/bin/sh
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