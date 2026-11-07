#!/bin/sh
# Заголовок шага: пустая строка сверху и снизу.
# _BLANK=1 значит, что последним был log_done и пустая строка уже стоит снизу;
# тогда следующий log не добавляет свою, и между двумя log остаётся одна строка.
_BLANK=
log()      { [ -n "$_BLANK" ] || printf '\n'; printf '==> %s\n\n' "$*"; _BLANK=; }
log_done() { log "$@"; _BLANK=1; }   # последний log шага
warn()     { _BLANK=; printf '!! %s\n' "$*"; }

ESC=$(printf '\033')

# Убирает маркеры bracketed paste (ESC[200~ и ESC[201~), которые терминал
# добавляет при вставке: без этого они попадали бы в ссылки и пароли.
clean_paste() {
    printf '%s' "$1" | sed "s/${ESC}\[20[01]~//g"
}

# Возвращает свободное место в /overlay в MiB (округление вниз).
# Значение вычисляется при каждом вызове, поэтому учитывает уже установленные пакеты.
get_free_space() {
    df -k /overlay | awk 'NR==2 {print int($4 / 1024)}'
}

# ask_yn "Вопрос": код возврата 0, если ответили y/yes
ask_yn() {
    _BLANK=
    printf '%s [y/N]: ' "$1"
    read -r _ans
    _ans=$(clean_paste "$_ans")
    case "$_ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ask "Вопрос" "по умолчанию": ответ кладёт в $ANSWER
ask() {
    _BLANK=
    printf '%s [%s]: ' "$1" "$2"
    read -r ANSWER
    ANSWER=$(clean_paste "$ANSWER")
    ANSWER="${ANSWER:-$2}"
}

# Проверка наличия пакета и короткая обёртка над apk add.
pkg_installed() { apk info -e "$1" >/dev/null 2>&1; }
pkg_add()       { apk add "$@"; }
refresh_package_index() { apk update; }

# Скачивает и запускает сторонний установщик через временный файл.
# Process substitution не поддерживается некоторыми реализациями /bin/sh в OpenWrt.
run_remote_installer() {
    _installer_url=$1
    if ! command -v wget >/dev/null 2>&1; then
        refresh_package_index || return 1
        pkg_add wget-ssl || return 1
    fi
    _installer_file=$(mktemp /tmp/openwrt-installer.XXXXXX) || {
        warn "Не удалось создать временный файл установщика"
        return 1
    }

    if ! wget -qO "$_installer_file" "$_installer_url" || [ ! -s "$_installer_file" ]; then
        rm -f "$_installer_file"
        warn "Не удалось скачать установщик: $_installer_url"
        return 1
    fi

    sh "$_installer_file"
    _installer_status=$?
    rm -f "$_installer_file"
    return "$_installer_status"
}

# Создание случайных имен для секций
rand_id() { tr -dc 'a-f0-9' </dev/urandom | head -c 6; }

# Результат: LINK_KIND (url|subscription) и LINK. Возврат 1 — пользователь пропустил.
ask_link() {
    while true; do
        ask "Добавить ссылку на сервер(1) или подписку(2) (1/2/N)?" "N"
        case "$ANSWER" in
            1) _kind=url;          _q="Вставь ссылку на сервер:";   _def="vless://" ;;
            2) _kind=subscription; _q="Вставь ссылку на подписку:"; _def="https://" ;;
            N|n) return 1 ;;
            *) warn "Некорректный ввод"; continue ;;
        esac

        ask "$_q" "$_def"
        case "$ANSWER" in
            *[![:print:]]*|*' '*) warn "Недопустимые символы в ссылке"; continue ;;
        esac

        if [ "$_kind" = url ]; then
            case "$ANSWER" in
                vless://?*|vmess://?*|ss://?*|trojan://?*|socks4://?*|socks5://?*|hy2://?*|hysteria2://?*|tuic://?*|anytls://?*|naive+https://?*|https://?*) ;;
                *) warn "Неподдерживаемый формат ссылки"; continue ;;
            esac
        else
            case "$ANSWER" in
                https://?*) ;;
                *) warn "Неподдерживаемый формат подписки"; continue ;;
            esac
        fi

        LINK_KIND=$_kind
        LINK=$ANSWER
        return 0
    done
}

# OpenClash требует dnsmasq-full вместо dnsmasq (взаимоисключающие, как wpad).
# На время замены локального DNS нет, поэтому временно берём публичные резолверы.
ensure_dnsmasq_full() {
    # Если уже установлен полный вариант, ничего не меняем.
    pkg_installed dnsmasq-full && return 0
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf
    if pkg_installed dnsmasq; then
        apk del dnsmasq || return 1
    fi
    pkg_add dnsmasq-full
}

# Промежуточный шаг после AGH: проверяем, что список пакетов снова доступен.
# Сразу после перезапуска AGH его DoH-upstream может быть ещё не готов.
ensure_connectivity() {
    # Несколько попыток дают AGH время поднять DoH-upstream после перезапуска.
    log "Проверка соединения"
    for _t in 1 2 3 4 5; do
        apk update >/dev/null 2>&1 && return 0
        sleep 3
    done
    warn "DNS не отвечает, временно беру 1.1.1.1 и 8.8.8.8 (до перезапуска dnsmasq или перезагрузки)"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf
    apk update || { warn "Связи нет, дальше не продолжаю"; exit 1; }
}
