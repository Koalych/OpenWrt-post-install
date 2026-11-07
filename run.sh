#!/bin/sh

TMP_DIR=$(mktemp -d /tmp/openwrt-post-install.XXXXXX) || exit 1
trap 'rm -rf "$TMP_DIR"' 0

ARCHIVE="$TMP_DIR/repository.tar.gz"
REPO_URL="https://codeload.github.com/Koalych/OpenWrt-post-install/tar.gz/refs/heads/main"

echo "Скачивание проекта..."
if ! wget -qO "$ARCHIVE" "$REPO_URL" || [ ! -s "$ARCHIVE" ]; then
    echo "Ошибка: не удалось скачать репозиторий. Проверьте подключение и адрес." >&2
    exit 1
fi

if ! tar -xzf "$ARCHIVE" -C "$TMP_DIR"; then
    echo "Ошибка: не удалось распаковать репозиторий." >&2
    exit 1
fi

INSTALLER="$TMP_DIR/OpenWrt-post-install-main/install.sh"
if [ ! -s "$INSTALLER" ]; then
    echo "Ошибка: в репозитории не найден install.sh." >&2
    exit 1
fi

echo "Запуск установщика..."
sh "$INSTALLER" < /dev/tty
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo "Установщик завершился с ошибкой (код $STATUS)." >&2
fi
exit "$STATUS"
