#!/bin/sh

TMP="$(mktemp /tmp/openwrt-post-install.XXXXXX)" || exit 1
trap 'rm -f "$TMP"' 0

REPO="https://raw.githubusercontent.com/Koalych/OpenWrt-post-install/main/install.sh"
echo "Скачивание основного скрипта..."
if ! wget -qO "$TMP" "$REPO" || [ ! -s "$TMP" ]; then
    echo "Ошибка: не удалось скачать install.sh. Проверьте подключение и адрес репозитория." >&2
    exit 1
fi

echo "Запуск установки..."
sh "$TMP" < /dev/tty
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo "Установщик завершился с ошибкой (код $STATUS)." >&2
fi
exit "$STATUS"