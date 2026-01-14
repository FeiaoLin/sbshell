#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="/etc/sing-box/scripts"
MODE_FILE="/etc/sing-box/mode.conf"
MAX_WAIT=15
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')

is_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x sing-box >/dev/null 2>&1
    else
        pidof sing-box >/dev/null 2>&1
    fi
}

cleanup_tproxy() {
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box
    ip rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE 2>/dev/null
    if [ -n "$INTERFACE" ]; then
        ip route del local default dev "$INTERFACE" table $PROXY_ROUTE_TABLE 2>/dev/null
    fi
}

MODE=$(grep -oE '^MODE=.*' "$MODE_FILE" 2>/dev/null | cut -d'=' -f2)
if [ -z "$MODE" ]; then
    echo -e "${RED}MODE not set, skip firewall apply.${NC}"
    exit 1
fi

if [ "$MODE" = "TProxy" ]; then
    cleanup_tproxy
fi

echo -e "${CYAN}Waiting for sing-box to start...${NC}"
i=1
while [ $i -le $MAX_WAIT ]; do
    if is_running; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

if ! is_running; then
    echo -e "${RED}sing-box is not running, skip firewall apply.${NC}"
    exit 1
fi

if [ "$MODE" = "TProxy" ]; then
    echo -e "${GREEN}Applying TProxy firewall rules...${NC}"
    bash "$SCRIPT_DIR/configure_tproxy.sh"
elif [ "$MODE" = "TUN" ]; then
    echo -e "${GREEN}Applying TUN firewall rules...${NC}"
    bash "$SCRIPT_DIR/configure_tun.sh"
else
    echo -e "${RED}Unknown MODE: $MODE${NC}"
    exit 1
fi
