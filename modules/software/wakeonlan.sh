#!/bin/sh
# Устанавливает утилиту и LuCI-интерфейс для отправки Wake-on-LAN пакетов.
step_wol() {
    ask_yn "Установить Wake-on-LAN?" || return 0
    pkg_add etherwake luci-app-wol
    log_done "Свободное место: $(get_free_space) MB"
}