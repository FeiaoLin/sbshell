#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

check_mode() {
    if nft list chain inet sing-box prerouting_tproxy &>/dev/null || nft list chain inet sing-box output_tproxy &>/dev/null; then
        echo "TProxy 模式"
    else
        echo "TUN 模式"
    fi
}

runtime_mode() {
    grep -E '^MODE=' /etc/sing-box/mode.conf 2>/dev/null | sed 's/^MODE=//'
}

check_runtime_health() {
    local mode
    mode="$(runtime_mode)"

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

start_singbox() {
    echo -e "${CYAN}检测是否处于非代理环境...${NC}"
    STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://www.google.com")

    if [ "$STATUS_CODE" -eq 200 ]; then
        echo -e "${RED}当前网络处于代理环境, 启动 sing-box 需要直连!${NC}"
    else
        echo -e "${CYAN}当前网络环境非代理网络，可以启动 sing-box。${NC}"
    fi

    local attempt ok i
    for attempt in 1 2; do
        if [ "$attempt" -eq 1 ]; then
            /etc/init.d/sing-box start >/dev/null 2>&1
        else
            echo -e "${CYAN}首次健康检查未通过，重启并再次预热...${NC}"
            /etc/init.d/sing-box restart >/dev/null 2>&1
        fi

        # 预热等待：给 sing-box 时间下载规则集、解析节点域名并完成首次延迟测试，
        # 避免 urltest 尚未选定节点导致健康检查误报
        ok=1
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if check_runtime_health; then
                ok=0
                break
            fi
            sleep 3
        done

        if [ "$ok" -eq 0 ]; then
            echo -e "${GREEN}sing-box 启动成功，运行状态正常${NC}"
            mode=$(check_mode)
            echo -e "${MAGENTA}当前启动模式: ${mode}${NC}"
            return 0
        fi
    done

    echo -e "${RED}sing-box 已尝试重启 2 次仍未通过健康检查，请检查: logread -e sing-box${NC}"
    return 1
}

read -rp "是否启动 sing-box?(y/n): " confirm_start
if [[ "$confirm_start" =~ ^[Yy]$ ]]; then
    start_singbox
else
    echo -e "${CYAN}已取消启动 sing-box。${NC}"
    exit 0
fi
