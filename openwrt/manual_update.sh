#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 手动输入的配置文件
MANUAL_FILE="/etc/sing-box/manual.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"

# 获取当前模式
MODE=$(grep '^MODE=' /etc/sing-box/mode.conf | sed 's/^MODE=//')

# 提示用户是否更换订阅的函数
prompt_user_input() {
    while true; do
        read -rp "请输入后端地址(不填使用默认值): " BACKEND_URL
        if [ -z "$BACKEND_URL" ]; then
            BACKEND_URL=$(grep BACKEND_URL "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [ -z "$BACKEND_URL" ]; then
                echo -e "${RED}未设置默认值，请在菜单中设置！${NC}"
                continue
            fi
            echo -e "${CYAN}使用默认后端地址: $BACKEND_URL${NC}"
        fi
        break
    done

    while true; do
        read -rp "请输入订阅地址(不填使用默认值): " SUBSCRIPTION_URL
        if [ -z "$SUBSCRIPTION_URL" ]; then
            SUBSCRIPTION_URL=$(grep SUBSCRIPTION_URL "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [ -z "$SUBSCRIPTION_URL" ]; then
                echo -e "${RED}未设置默认值，请在菜单中设置！${NC}"
                continue
            fi
            echo -e "${CYAN}使用默认订阅地址: $SUBSCRIPTION_URL${NC}"
        fi
        break
    done

    while true; do
        read -rp "请输入配置文件地址(不填使用默认值): " TEMPLATE_URL
        if [ -z "$TEMPLATE_URL" ]; then
            if [ "$MODE" = "TProxy" ]; then
                TEMPLATE_URL=$(grep TPROXY_TEMPLATE_URL "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)
                if [ -z "$TEMPLATE_URL" ]; then
                    echo -e "${RED}未设置默认值，请在菜单中设置！${NC}"
                    continue
                fi
                echo -e "${CYAN}使用默认 TProxy 配置文件地址: $TEMPLATE_URL${NC}"
            elif [ "$MODE" = "TUN" ]; then
                TEMPLATE_URL=$(grep TUN_TEMPLATE_URL "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)
                if [ -z "$TEMPLATE_URL" ]; then
                    echo -e "${RED}未设置默认值，请在菜单中设置！${NC}"
                    continue
                fi
                echo -e "${CYAN}使用默认 TUN 配置文件地址: $TEMPLATE_URL${NC}"
            else
                echo -e "${RED}未知的模式: $MODE${NC}"
                exit 1
            fi
        fi
        break
    done
}

check_runtime_health() {
    local mode
    mode=$(grep -E '^MODE=' /etc/sing-box/mode.conf 2>/dev/null | sed 's/^MODE=//')

    /etc/init.d/sing-box status 2>/dev/null | grep -q "running" || return 1

    if [ "$mode" = "TProxy" ]; then
        nft list table inet sing-box >/dev/null 2>&1 || return 1
        ip rule show | grep -q "fwmark 0x1 lookup 100" || return 1
        ip route show table 100 | grep -q "local default dev lo" || return 1
    fi

    curl -4 -sS -o /dev/null --max-time 10 "https://www.gstatic.com/generate_204" >/dev/null 2>&1 && return 0
    curl -4 -sS -o /dev/null --max-time 10 "https://www.google.com" >/dev/null 2>&1 && return 0
    return 1
}

read -rp "是否更换订阅地址？(y/n): " change_subscription
if [[ "$change_subscription" =~ ^[Yy]$ ]]; then
    # 执行手动输入相关内容
    while true; do
        prompt_user_input

        echo -e "${CYAN}你输入的配置信息如下:${NC}"
        echo "后端地址: $BACKEND_URL"
        echo "订阅地址: $SUBSCRIPTION_URL"
        echo "配置文件地址: $TEMPLATE_URL"

        read -rp "确认输入的配置信息？(y/n): " confirm_choice
        if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
            # 更新手动输入的配置文件
            cat > "$MANUAL_FILE" <<EOF
BACKEND_URL=$BACKEND_URL
SUBSCRIPTION_URL=$SUBSCRIPTION_URL
TEMPLATE_URL=$TEMPLATE_URL
EOF

            echo "手动输入的配置已更新"
            break
        else
            echo -e "${RED}请重新输入配置信息。${NC}"
        fi
    done
else
    if [ ! -f "$MANUAL_FILE" ]; then
        echo -e "${RED}订阅地址为空，请设置！${NC}"
        exit 1
    fi

    # 使用现有配置，并输出调试信息
    BACKEND_URL=$(grep BACKEND_URL "$MANUAL_FILE" 2>/dev/null | cut -d'=' -f2-)
    SUBSCRIPTION_URL=$(grep SUBSCRIPTION_URL "$MANUAL_FILE" 2>/dev/null | cut -d'=' -f2-)
    TEMPLATE_URL=$(grep TEMPLATE_URL "$MANUAL_FILE" 2>/dev/null | cut -d'=' -f2-)

    if [ -z "$BACKEND_URL" ] || [ -z "$SUBSCRIPTION_URL" ] || [ -z "$TEMPLATE_URL" ]; then
        echo -e "${RED}订阅地址为空，请设置！${NC}"
        exit 1
    fi

    echo -e "${CYAN}当前配置如下:${NC}"
    echo "后端地址: $BACKEND_URL"
    echo "订阅地址: $SUBSCRIPTION_URL"
    echo "配置文件地址: $TEMPLATE_URL"
fi

# 构建完整的配置文件URL
FULL_URL="${BACKEND_URL}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
echo "生成完整订阅链接: $FULL_URL"

# 备份现有配置文件
[ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json /etc/sing-box/config.json.backup

if curl -L --connect-timeout 10 --max-time 30 "$FULL_URL" -o /etc/sing-box/config.json; then
    echo -e "${GREEN}配置文件更新成功!${NC}"
    if ! sing-box check -c /etc/sing-box/config.json; then
        echo -e "${RED}配置文件验证失败，恢复备份...${NC}"
        [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
    fi
else
    echo -e "${RED}配置文件下载失败，恢复备份...${NC}"
    [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
fi

# 重载 sing-box 并检查可用性，失败自动重试一次
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

echo -e "${RED}sing-box 已重试 2 次仍未通过健康检查，请执行: logread -e sing-box${NC}"
exit 1
