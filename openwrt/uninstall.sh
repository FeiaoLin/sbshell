#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="/etc/sing-box/scripts"
SINGBOX_DIR="/etc/sing-box"
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100

cleanup_firewall() {
    # nft 表（同时覆盖 IPv4/IPv6）
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box

    # 策略路由：configure_tproxy 写入时绑定在 lo 上，且含 IPv6，必须按同样方式清理
    ip rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE 2>/dev/null
    ip route del local default dev lo table $PROXY_ROUTE_TABLE 2>/dev/null
    ip -6 rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE 2>/dev/null
    ip -6 route del local ::/0 dev lo table $PROXY_ROUTE_TABLE 2>/dev/null

    # 兜底：兼容老版本把路由绑在默认网卡上的情况
    local iface
    iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -n "$iface" ]; then
        ip route del local default dev "$iface" table $PROXY_ROUTE_TABLE 2>/dev/null
        ip -6 route del local default dev "$iface" table $PROXY_ROUTE_TABLE 2>/dev/null
    fi
}

cleanup_cron() {
    # 移除自动更新/面板更新遗留的定时任务（引用已被删除的脚本路径）
    local lines
    lines="$(crontab -l 2>/dev/null)"
    [ -n "$lines" ] || return 0
    echo "$lines" \
        | grep -Ev 'update-singbox\.sh|update-ui\.sh|/etc/sing-box/' \
        | crontab - 2>/dev/null
}

echo -e "${RED}This will uninstall sing-box and remove all scripts/config/cache. Continue? (y/n): ${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Canceled.${NC}"
    exit 0
fi

# 1. 停止并禁用服务
if [ -f /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box stop >/dev/null 2>&1
    /etc/init.d/sing-box disable >/dev/null 2>&1
fi

# 2. 清理防火墙规则与策略路由（IPv4/IPv6, dev lo + 网卡兜底）
cleanup_firewall

# 3. 移除自动更新等孤儿定时任务
cleanup_cron

# 4. 移除 sb 命令与 bashrc 别名
rm -f /usr/bin/sb
if [ -f ~/.bashrc ]; then
    sed -i '/alias sb=/d' ~/.bashrc
fi

# 5. 删除 sing-box 全部数据/脚本/配置/缓存/面板（含 mode.conf、defaults.conf、cache.db、update-*.sh、ui）
rm -rf "$SINGBOX_DIR"

# 6. 卸载 sing-box 软件包并删除 init 脚本
opkg remove sing-box >/dev/null 2>&1
rm -f /etc/init.d/sing-box

# 7. 清理升级/安装残留的临时目录与日志
rm -rf /tmp/sing-box /tmp/sing-box-ui /tmp/sing-box-ui_backup 2>/dev/null
rm -rf /tmp/sing-box-upgrade.* /tmp/sing-box-install.* 2>/dev/null
rm -f /tmp/kmod-rollback.log /tmp/sbshell-opkg-update.log 2>/dev/null

# 8. （可选）删除 sbshell 为 TProxy 安装的内核模块
if opkg list-installed 2>/dev/null | grep -Eq '^(kmod-nft-tproxy|kmod-nft-queue) '; then
    echo
    read -rp "是否同时删除 sbshell 安装的内核模块 kmod-nft-tproxy / kmod-nft-queue?(y/n, 默认n): " rm_kmod
    if [[ "$rm_kmod" =~ ^[Yy]$ ]]; then
        opkg remove kmod-nft-tproxy >/dev/null 2>&1
        opkg remove kmod-nft-queue >/dev/null 2>&1
        echo -e "${CYAN}已删除内核模块。${NC}"
    else
        echo -e "${YELLOW}已保留内核模块，可稍后手动删除。${NC}"
    fi
fi

echo -e "${GREEN}Uninstall completed.${NC}"
echo -e "${YELLOW}提示：系统通用工具(curl/bash/nftables/unzip)非 sbshell 专用依赖，为避免影响系统未自动删除。${NC}"
