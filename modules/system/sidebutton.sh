#!/bin/sh
step_button() {
    ask_yn "Восстановить работу слайдера боковой панели GL-MT3000 на OpenWrt?" || return 0
    mkdir -p /etc/hotplug.d/button
    cat > /etc/hotplug.d/button/50-mode-switch << 'EOF'
#!/bin/sh
[ "$BUTTON" = "BTN_0" ] || exit 0

case "$ACTION" in
    pressed)
        logger -t mode-switch "Переключено в положение 1"
        # ваша логика для положения 1
        ;;
    released)
        logger -t mode-switch "Переключено в положение 2"
        # ваша логика для положения 2
        ;;
esac
EOF
chmod +x /etc/hotplug.d/button/50-mode-switch
log_done "Завершено. Задать логику слайдера можно в файле /etc/hotplug.d/button/50-mode-switch"
}