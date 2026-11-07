#!/bin/sh
# Проверяет минимальные условия запуска и подтверждает целевое устройство.
step_preflight() {
    [ -x /usr/bin/apk ] || {
        warn "Скрипт рассчитан на OpenWrt 25.12+ (нужен apk). Читай README."
        exit 1
    }
    ask_yn "Скрипт ориентирован на GL-MT3000; на других устройствах возможны отличия. Продолжить?" || exit 0
}

# Выбор страны определяет часовой пояс, код страны Wi-Fi и набор обходов
# Сохраняет выбранные параметры страны в глобальные переменные для следующих шагов.
step_country() {
    ask "Страна: (1) Россия / (2) Вьетнам / (3) другая" "1"
    case "$ANSWER" in
        1) COUNTRY=ru;    WIFI_CC=RU; TZ_NAME='Europe/Moscow';    TZ_POSIX='MSK-3' ;;
        2) COUNTRY=vn;    WIFI_CC=VN; TZ_NAME='Asia/Ho_Chi_Minh'; TZ_POSIX='ICT-7' ;;
        3) COUNTRY=other; TZ_NAME='UTC'; TZ_POSIX='UTC0'
           ask "Двухбуквенный код страны для Wi-Fi (например US)" "US"
           WIFI_CC="$ANSWER" ;;
        *) COUNTRY=ru;    WIFI_CC=00; TZ_NAME='UTC'; TZ_POSIX='UTC0' ;;
    esac
}

# Настраивает интерфейс LuCI, hostname, часовой пояс и пароль root.
step_system() {
    log "LuCI и система"
    uci set luci.main.lang='ru'
    ask "Тема LuCI: (1) светлая / (2) тёмная" "2"
    case "$ANSWER" in
        1) uci set luci.main.mediaurlbase='/luci-static/bootstrap-light' ;;
        *) uci set luci.main.mediaurlbase='/luci-static/bootstrap-dark' ;;
    esac
    uci set luci.main.tablefilters='1'
    uci set attendedsysupgrade.client.login_check_for_upgrades='1'

    ask "Hostname" "OpenWRT"
    uci set system.@system[0].hostname="$ANSWER"
    uci set system.@system[0].timezone="$TZ_POSIX"
    uci set system.@system[0].zonename="$TZ_NAME"
    uci set system.@system[0].clock_hourcycle='h23'
    uci set system.@system[0].clock_timestyle='1'
    uci commit

    if ask_yn "Установить пароль root?"; then
        until passwd; do warn "Ошибка выполнения, повтори"; done
    fi
}

# Финальный шаг: предлагает перезагрузку после изменения системных служб и сетевых настроек.
step_finish() {
    log "Готово"
    if ask_yn "Перезагрузить сейчас? (рекомендуется)"; then
        reboot
    else
        echo "Без перезагрузки. Службы могут потребовать ручного перезапуска."
    fi
}