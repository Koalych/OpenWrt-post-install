#!/bin/sh
# Общий порядок установки. Страновая ветка вызывается последней среди основных
# настроек; её ошибка завершает скрипт, а успешное выполнение ведёт к переводам и MOTD.
setup_ru() {
    while true; do
        ask "Установить Forkop (1) или Netshift (2) (1/2/N)?" "N"
        case "$ANSWER" in
            1) forkop_install; return $? ;;
            2) netshift_install; return $? ;;
            N|n) return 0 ;;
            *) warn "Некорректный ввод" ;;
        esac
    done
}

setup_vn() {
    openclash_install
}

main() {
    step_lan
    step_country
    step_base_packages || exit 1
    step_personal_packages
    step_additional_packages
    step_system
    step_wifi || exit 1
    step_storage
    agh_install || exit 1
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
