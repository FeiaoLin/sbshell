#!/bin/bash

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE="/etc/sing-box/manual.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"

cat > /etc/sing-box/update-singbox.sh <<'EOF'
#!/bin/bash

MANUAL_FILE="/etc/sing-box/manual.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"

get_value() {
    local file="$1"
    local key="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2-
}

mode=$(grep -E '^MODE=' /etc/sing-box/mode.conf 2>/dev/null | sed 's/^MODE=//' | tr -d '\r' | xargs)
if [ "$mode" = "TProxy" ] || [ "$mode" = "tproxy" ]; then
    key="TPROXY_SUBSCRIPTION_URL"
elif [ "$mode" = "TUN" ] || [ "$mode" = "tun" ]; then
    key="TUN_SUBSCRIPTION_URL"
else
    echo "未知模式: ${mode:-<empty>}"
    exit 1
fi

FULL_URL=$(get_value "$MANUAL_FILE" "$key")
[ -z "$FULL_URL" ] && FULL_URL=$(get_value "$DEFAULTS_FILE" "$key")

if [ -z "$FULL_URL" ]; then
    echo "当前模式订阅地址为空: $key"
    exit 1
fi

[ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json /etc/sing-box/config.json.backup

if curl -L --connect-timeout 10 --max-time 30 "$FULL_URL" -o /etc/sing-box/config.json; then
    if ! sing-box check -c /etc/sing-box/config.json; then
        echo "新配置文件校验失败，恢复备份..."
        [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
        exit 1
    fi
else
    echo "下载配置文件失败，恢复备份..."
    [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
    exit 1
fi

/etc/init.d/sing-box restart
EOF

chmod a+x /etc/sing-box/update-singbox.sh

while true; do
    echo -e "${CYAN}请选择操作:${NC}"
    echo "1. 设置自动更新间隔"
    echo "2. 取消自动更新"
    read -rp "请输入选项 (1或2, 默认1): " menu_choice
    menu_choice=${menu_choice:-1}

    if [[ "$menu_choice" == "1" ]]; then
        while true; do
            read -rp "请输入更新间隔小时数 (1-23, 默认12): " interval_choice
            interval_choice=${interval_choice:-12}

            if [[ "$interval_choice" =~ ^[1-9]$|^1[0-9]$|^2[0-3]$ ]]; then
                break
            else
                echo -e "${RED}输入无效，请输入 1-23${NC}"
            fi
        done

        if crontab -l 2>/dev/null | grep -q '/etc/sing-box/update-singbox.sh'; then
            echo -e "${RED}检测到已有自动更新任务${NC}"
            read -rp "是否重新设置？(y/n): " confirm_reset
            if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
                crontab -l 2>/dev/null | grep -v '/etc/sing-box/update-singbox.sh' | crontab -
                echo "已删除旧的自动更新任务"
            else
                echo -e "${CYAN}保持已有任务，退出${NC}"
                exit 0
            fi
        fi

        (crontab -l 2>/dev/null; echo "0 */$interval_choice * * * /etc/sing-box/update-singbox.sh") | crontab -
        /etc/init.d/cron restart

        echo "定时更新任务已设置，每 $interval_choice 小时执行一次"
        break

    elif [[ "$menu_choice" == "2" ]]; then
        if crontab -l 2>/dev/null | grep -q '/etc/sing-box/update-singbox.sh'; then
            crontab -l 2>/dev/null | grep -v '/etc/sing-box/update-singbox.sh' | crontab -
            /etc/init.d/cron restart
            echo -e "${CYAN}自动更新任务已取消${NC}"
        else
            echo -e "${CYAN}没有找到自动更新任务${NC}"
        fi
        break

    else
        echo -e "${RED}输入无效, 请输入 1 或 2${NC}"
    fi
done
