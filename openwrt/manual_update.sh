#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
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

resolve_current_url() {
    local key="$1"
    local value
    value=$(get_value "$MANUAL_FILE" "$key")
    [ -z "$value" ] && value=$(get_value "$DEFAULTS_FILE" "$key")
    echo "$value"
}

check_runtime_health() {
    local mode
    mode=$(grep -E '^MODE=' /etc/sing-box/mode.conf 2>/dev/null | sed 's/^MODE=//' | tr -d '\r' | xargs)

    /etc/init.d/sing-box status 2>/dev/null | grep -q "running" || return 1

    if [ "$mode" = "TProxy" ] || [ "$mode" = "tproxy" ]; then
        nft list table inet sing-box >/dev/null 2>&1 || return 1
        ip rule show | grep -q "fwmark 0x1 lookup 100" || return 1
        ip route show table 100 | grep -q "local default dev lo" || return 1
    fi

    curl -4 -sS -o /dev/null --max-time 10 "https://www.gstatic.com/generate_204" >/dev/null 2>&1 && return 0
    curl -4 -sS -o /dev/null --max-time 10 "https://www.google.com" >/dev/null 2>&1 && return 0
    return 1
}

MODE_KEY=$(get_mode_key)
if [ -z "$MODE_KEY" ]; then
    echo -e "${RED}未知模式: $MODE, 请先在菜单 1 里切换模式${NC}"
    exit 1
fi

TPROXY_SUBSCRIPTION_URL=$(resolve_current_url "TPROXY_SUBSCRIPTION_URL")
TUN_SUBSCRIPTION_URL=$(resolve_current_url "TUN_SUBSCRIPTION_URL")

read -rp "是否修改当前模式订阅地址？(y/n): " change_subscription
if [[ "$change_subscription" =~ ^[Yy]$ ]]; then
    if [ "$MODE_KEY" = "TPROXY_SUBSCRIPTION_URL" ]; then
        read -rp "请输入TProxy订阅地址(不填使用默认): " input_url
        input_url=${input_url:-$TPROXY_SUBSCRIPTION_URL}
        TPROXY_SUBSCRIPTION_URL="$input_url"
    else
        read -rp "请输入TUN订阅地址(不填使用默认): " input_url
        input_url=${input_url:-$TUN_SUBSCRIPTION_URL}
        TUN_SUBSCRIPTION_URL="$input_url"
    fi

    if [ -z "$input_url" ]; then
        echo -e "${RED}订阅地址为空，请先在默认参数中设置${NC}"
        exit 1
    fi

    write_manual_file
fi

FULL_URL=$(resolve_current_url "$MODE_KEY")
if [ -z "$FULL_URL" ]; then
    echo -e "${RED}当前模式订阅地址为空${NC}"
    exit 1
fi

echo -e "${CYAN}下载地址: $FULL_URL${NC}"

[ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json /etc/sing-box/config.json.backup

if curl -L --connect-timeout 10 --max-time 30 "$FULL_URL" -o /etc/sing-box/config.json; then
    echo -e "${GREEN}配置文件更新成功${NC}"
    if ! sing-box check -c /etc/sing-box/config.json; then
        echo -e "${RED}配置文件校验失败，恢复备份${NC}"
        [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
        exit 1
    fi
else
    echo -e "${RED}配置文件下载失败，恢复备份${NC}"
    [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
    exit 1
fi

for attempt in 1 2; do
    if [ "$attempt" -eq 1 ]; then
        /etc/init.d/sing-box restart >/dev/null 2>&1
    else
        /etc/init.d/sing-box stop >/dev/null 2>&1
        sleep 1
        /etc/init.d/sing-box start >/dev/null 2>&1
    fi

    sleep 2
    if check_runtime_health; then
        echo -e "${GREEN}sing-box 启动成功，新配置已生效${NC}"
        exit 0
    fi
done

echo -e "${RED}sing-box 重试 2 次仍未通过健康检查，请执行 logread -e sing-box${NC}"
exit 1
