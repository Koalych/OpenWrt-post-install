#!/bin/sh
# OpenWrt-post-install
# Цель: чистая OpenWrt 25.12+ (пакетный менеджер apk). Изначально под GL-MT3000.
#
# Структура проекта:
#   core/helpers.sh — общие функции и вывод сообщений;
#   core/main.sh — последовательность полной настройки;
#   core/final.sh — итоговые сводки после установки;
#   modules/network/ — настройка LAN и Wi-Fi;
#   modules/software/ — системные настройки и установка программ;
#   modules/system/ — шаги сценария, MOTD и боковой переключатель.
# Этот файл подключает модули, содержит интерактивное меню и запускает
# выбранные шаги или полный сценарий main.
#
# Принципы:
#   - секции uci создаём именованными (uci set x.name=type), а не через
#     `uci add`; исключение функция oc_dns; повторный запуск не плодит дубли;
#   - адрес и подсеть LAN берём из конфига, а не зашиваем;
#   - если LAN-адрес меняется, SSH-сессия обрывается: подключись по новому
#     адресу и запусти скрипт ещё раз;
#   - ошибка в страновой ветке (Forkop/Netshift/OpenClash) останавливает main,
#     чтобы последующие шаги не маскировали неудачную установку.

_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$_SCRIPT_DIR/core/helpers.sh"
. "$_SCRIPT_DIR/core/main.sh"
. "$_SCRIPT_DIR/core/final.sh"
. "$_SCRIPT_DIR/modules/network/lan.sh"
. "$_SCRIPT_DIR/modules/network/wifi.sh"
. "$_SCRIPT_DIR/modules/software/agh.sh"
. "$_SCRIPT_DIR/modules/software/forkop.sh"
. "$_SCRIPT_DIR/modules/software/netshift.sh"
. "$_SCRIPT_DIR/modules/software/openclash.sh"
. "$_SCRIPT_DIR/modules/software/system.sh"
. "$_SCRIPT_DIR/modules/software/tailscale.sh"
. "$_SCRIPT_DIR/modules/software/transmission.sh"
. "$_SCRIPT_DIR/modules/software/wakeonlan.sh"
. "$_SCRIPT_DIR/modules/system/randommotd.sh"
. "$_SCRIPT_DIR/modules/system/sidebutton.sh"
. "$_SCRIPT_DIR/modules/system/steps.sh"

show_menu() {
    clear
    printf '\n========== OpenWrt Post Install ==========\n'
    printf '1. Система\n'
    printf '2. Сеть\n'
    printf '3. Программы\n'
    printf '4. Дополнительные настройки\n'
    printf '5. Полная настройка\n'
    printf '0. Выход\n\n'
    printf 'Выбери действие: '
}

system_menu() {
    clear
    printf '\n========== Система ==========\n'
    printf '1. Обновление и базовые пакеты\n'
    printf '2. Дополнительные пакеты\n'
    printf '3. Настройка системы и времени\n'
    printf '4. Настройка MOTD\n'
    printf '5. Изменить оболочку (пока не реализовано)\n'
    printf '6. Настройка SSH (пока не реализовано)\n'
    printf '0. Назад\n\n'
    printf 'Выбери действие: '
}

network_menu() {
    clear
    printf '\n========== Сеть ==========\n'
    printf '1. Настроить LAN\n'
    printf '2. Настроить Wi-Fi\n'
    printf '3. Установить AdGuard Home\n'
    printf '0. Назад\n\n'
    printf 'Выбери действие: '
}

programs_menu() {
    clear
    printf '\n========== Программы ==========\n'
    printf '1. Установить Forkop или Netshift\n'
    printf '2. Установить OpenClash\n'
    printf '3. Установить Tailscale\n'
    printf '4. Установить Wake-on-LAN\n'
    printf '5. Настроить USB-накопитель и Transmission\n'
    printf '0. Назад\n\n'
    printf 'Выбери действие: '
}

additional_menu() {
    clear
    printf '\n========== Дополнительные настройки ==========\n'
    printf '1. Настроить MOTD\n'
    printf '2. Настроить боковой переключатель GL-MT3000\n'
    printf '0. Назад\n\n'
    printf 'Выбери действие: '
}

menu() {
    while true; do
        show_menu
        read -r _menu_choice || return 0
        case "$_menu_choice" in
            1)
                system_menu
                read -r _section_choice || continue
                case "$_section_choice" in
                    1) step_preflight && step_base_packages ;;
                    2) step_preflight && step_personal_packages && step_additional_packages ;;
                    3) step_preflight && step_country && step_system ;;
                    4) step_preflight && step_banners ;;
                    5|6) printf 'Этот пункт пока не реализован.\n' ;;
                    0) ;;
                    *) printf 'Некорректный ввод.\n' ;;
                esac
                ;;
            2)
                network_menu
                read -r _section_choice || continue
                case "$_section_choice" in
                    1) step_preflight && step_lan ;;
                    2) step_preflight && step_country && step_wifi ;;
                    3) step_preflight && step_country && step_dns ;;
                    0) ;;
                    *) printf 'Некорректный ввод.\n' ;;
                esac
                ;;
            3)
                programs_menu
                read -r _section_choice || continue
                case "$_section_choice" in
                    1) step_preflight && setup_ru ;;
                    2) step_preflight && setup_vn ;;
                    3) step_preflight && step_tailscale ;;
                    4) step_preflight && step_wol ;;
                    5) step_preflight && step_storage ;;
                    0) ;;
                    *) printf 'Некорректный ввод.\n' ;;
                esac
                ;;
            4)
                additional_menu
                read -r _section_choice || continue
                case "$_section_choice" in
                    1) step_preflight && step_banners ;;
                    2) step_preflight && step_button ;;
                    0) ;;
                    *) printf 'Некорректный ввод.\n' ;;
                esac
                ;;
            5) main "$@" ;;
            0) return 0 ;;
            *) printf 'Некорректный ввод.\n' ;;
        esac
    done
}

menu "$@"
