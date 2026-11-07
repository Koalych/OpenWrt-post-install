#!/bin/sh
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