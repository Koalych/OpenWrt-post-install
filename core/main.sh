#!/bin/sh
# Общий порядок установки. Страновая ветка вызывается последней среди основных
# настроек; её ошибка завершает скрипт, а успешное выполнение ведёт к переводам и MOTD.
main() {
    step_preflight
    step_lan
    step_country
    step_base_packages || exit 1
    step_personal_packages
    step_additional_packages
    step_system
    step_wifi || exit 1
    step_storage
    step_dns || exit 1
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
