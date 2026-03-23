#!/bin/bash

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE="/etc/sing-box/manual.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"

MODE=$(grep -E '^MODE=' /etc/sing-box/mode.conf 2>/dev/null | sed 's/^MODE=//' | tr -d '\r' | xargs)

get_mode_key() {
    if [ "$MODE" = "TProxy" ] || [ "$MODE" = "tproxy" ]; then
        echo "TPROXY_SUBSCRIPTION_URL"
    elif [ "$MODE" = "TUN" ] || [ "$MODE" = "tun" ]; then
        echo "TUN_SUBSCRIPTION_URL"
    else
        echo ""
    fi
}

get_value() {
    local file="$1"
    local key="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2-
}

write_manual_file() {
    cat > "$MANUAL_FILE" <<EOF
TPROXY_SUBSCRIPTION_URL=$TPROXY_SUBSCRIPTION_URL
TUN_SUBSCRIPTION_URL=$TUN_SUBSCRIPTION_URL
EOF
}

MODE_KEY=$(get_mode_key)
if [ -z "$MODE_KEY" ]; then
    echo -e "${RED}未知模式: $MODE, 请先在菜单 1 里切换模式${NC}"
    exit 1
fi

TPROXY_SUBSCRIPTION_URL=$(get_value "$MANUAL_FILE" "TPROXY_SUBSCRIPTION_URL")
TUN_SUBSCRIPTION_URL=$(get_value "$MANUAL_FILE" "TUN_SUBSCRIPTION_URL")

[ -z "$TPROXY_SUBSCRIPTION_URL" ] && TPROXY_SUBSCRIPTION_URL=$(get_value "$DEFAULTS_FILE" "TPROXY_SUBSCRIPTION_URL")
[ -z "$TUN_SUBSCRIPTION_URL" ] && TUN_SUBSCRIPTION_URL=$(get_value "$DEFAULTS_FILE" "TUN_SUBSCRIPTION_URL")

if [ "$MODE_KEY" = "TPROXY_SUBSCRIPTION_URL" ]; then
    current_url="$TPROXY_SUBSCRIPTION_URL"
    prompt_text="请输入TProxy订阅地址"
else
    current_url="$TUN_SUBSCRIPTION_URL"
    prompt_text="请输入TUN订阅地址"
fi

read -rp "$prompt_text(回车使用默认): " input_url
input_url=${input_url:-$current_url}

if [ -z "$input_url" ]; then
    echo -e "${RED}订阅地址为空，请先在默认参数中设置${NC}"
    exit 1
fi

if [ "$MODE_KEY" = "TPROXY_SUBSCRIPTION_URL" ]; then
    TPROXY_SUBSCRIPTION_URL="$input_url"
else
    TUN_SUBSCRIPTION_URL="$input_url"
fi

FULL_URL="$input_url"

echo -e "${CYAN}下载地址: $FULL_URL${NC}"
read -rp "确认写入并下载配置?(y/n): " confirm_choice
if [[ ! "$confirm_choice" =~ ^[Yy]$ ]]; then
    exit 0
fi

write_manual_file

while true; do
    if curl -L --connect-timeout 10 --max-time 30 "$FULL_URL" -o /etc/sing-box/config.json; then
        if sing-box check -c /etc/sing-box/config.json; then
            echo "配置文件下载并校验成功"
            exit 0
        fi
        echo -e "${RED}配置文件校验失败${NC}"
        exit 1
    fi

    echo -e "${RED}配置文件下载失败${NC}"
    read -rp "是否重试下载?(y/n): " retry_choice
    if [[ "$retry_choice" =~ ^[Nn]$ ]]; then
        exit 1
    fi
done
