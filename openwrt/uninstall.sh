#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="/etc/sing-box/scripts"
SINGBOX_DIR="/etc/sing-box"
TMP_DIR="/tmp/sing-box"
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')

cleanup_firewall() {
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box
    ip rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE 2>/dev/null
    if [ -n "$INTERFACE" ]; then
        ip route del local default dev "$INTERFACE" table $PROXY_ROUTE_TABLE 2>/dev/null
    fi
}

echo -e "${RED}This will uninstall sing-box and remove all scripts/config/cache. Continue? (y/n): ${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Canceled.${NC}"
    exit 0
fi

if [ -f /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box stop >/dev/null 2>&1
    /etc/init.d/sing-box disable >/dev/null 2>&1
fi

cleanup_firewall

rm -f /usr/bin/sb
if [ -f ~/.bashrc ]; then
    sed -i '/alias sb=/d' ~/.bashrc
fi

rm -rf "$SINGBOX_DIR"
rm -rf "$TMP_DIR"

opkg remove sing-box >/dev/null 2>&1
rm -f /etc/init.d/sing-box

echo -e "${GREEN}Uninstall completed.${NC}"
