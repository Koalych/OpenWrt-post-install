#!/bin/sh
# Устанавливает поддержку USB-накопителей и, по желанию, Transmission.
# Сам накопитель здесь не размечается и не монтируется.
step_usb_storage() {
    USB_STORAGE_SELECTED=
    ask_yn "Есть USB-накопитель, планируешь использовать?" || return 0
    USB_STORAGE_SELECTED=1
    refresh_package_index || return 1
    pkg_add blockd kmod-fs-vfat kmod-usb-storage-uas kmod-usb2 kmod-usb3 lsblk || return 1

    ask "Файловая система накопителя: 1)ext4 2)exfat 3)ntfs N)другая (1/2/3/N)" "N"
    case "$ANSWER" in
        1) pkg_add kmod-fs-ext4 || return 1 ;;
        2) pkg_add kmod-fs-exfat || return 1 ;;
        3) pkg_add kmod-fs-ntfs3 || return 1 ;;
        N|n) ;;
        *) warn "Некорректный ввод" ;;
    esac
    log "Завершено"
    log_done "Поддержка USB-накопителя установлена. Свободное место: $(get_free_space) MB"
}

transmission_install() {
    ask_yn "Установить Transmission?" || return 0
    refresh_package_index || return 1
    pkg_add luci-i18n-transmission-ru transmission-web || return 1
    uci set transmission.@transmission[0].enabled='1'
    uci commit transmission

    log_done "Свободное место: $(get_free_space) MB"
}

# Сохранённый агрегат для сценария полной установки.
step_storage() {
    step_usb_storage || return 1
    [ "$USB_STORAGE_SELECTED" = 1 ] || return 0
    transmission_install
}
