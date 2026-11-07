#!/bin/sh
# Русские переводы LuCI: по одному пакету на каждый установленный luci-app-*.
# Ставим по одному, потому что apk работает транзакцией: если для какого-то
# приложения перевода нет, одна общая команда упала бы целиком.
install_luci_i18n() {
    # Список приложений считывается после установки всех выбранных компонентов.
    ask_yn "Установить русскую локализацию LuCI?" || return 0
    pkg_installed luci-i18n-base-ru || pkg_add luci-i18n-base-ru
    for _a in $(apk list -I 2>/dev/null | grep '^luci-app-' | sed -E 's/ .*//; s/-[0-9].*//'); do
        apk add "luci-i18n-${_a#luci-app-}-ru" >/dev/null 2>&1 || :
    done
    if pkg_installed luci-mod-dashboard; then
        pkg_add luci-i18n-dashboard-ru
    fi

    log_done "Свободное место: $(get_free_space) MB"
}

# Базовые инструменты, необходимые независимо от выбранной страны и дополнительных функций.
step_base_packages() {
    log "Обновление списка пакетов"
    apk update || return 1

    log "Установка основных пакетов"
    # Переводы приложений ставит install_luci_i18n в конце, когда все luci-app-* на месте
    pkg_add curl openssh-sftp-server luci-base || return 1
    log_done "Завершено. Свободное место: $(get_free_space) MB"
}

# Необязательный набор пакетов автора; отказ не влияет на дальнейшую установку.
step_personal_packages() {
    if ask_yn "Установить пакеты которые использует автор?
Список пакетов: bash, lsd, ripgrep, ss, btop, net-tools-netstat, luci-mod-dashboard, ncdu"; then
        refresh_package_index || return 1
        pkg_add bash lsd ripgrep ss btop net-tools-netstat luci-mod-dashboard ncdu
        log_done "Завершено. Свободное место: $(get_free_space) MB"
    fi
}

# Позволяет передать произвольный список имён пакетов в apk add.
# Ввод разделяется shell по пробелам; не предназначен для сложных имён с пробелами.
step_additional_packages() {
    if ask_yn "Нужны дополнительные пакеты?"; then
        printf 'Имена пакетов через пробел: '
        read -r _pk
        if [ -n "$_pk" ]; then
            refresh_package_index || return 1
            pkg_add $_pk || return 1
        fi
        log_done "Завершено. Свободное место: $(get_free_space) MB"
    fi
}
