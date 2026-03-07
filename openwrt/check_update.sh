#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
WORK_DIR="/tmp/sing-box-upgrade.$$"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 请使用 root 运行该脚本${NC}"
    exit 1
fi

if ! grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    echo -e "${RED}仅支持 OpenWrt 系统执行升级。${NC}"
    exit 1
fi

if ! command -v opkg >/dev/null 2>&1; then
    echo -e "${RED}未检测到 opkg，无法在 OpenWrt 上执行升级。${NC}"
    exit 1
fi

mkdir -p "$WORK_DIR" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT

fetch_text() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: sbshell" "$url"
        return $?
    fi
    wget -qO- --header="Accept: application/vnd.github+json" --header="User-Agent: sbshell" "$url"
}

download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --max-time 180 "$url" -o "$output"
        return $?
    fi
    wget -O "$output" "$url"
}

get_openwrt_arch() {
    opkg print-architecture 2>/dev/null \
        | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $2, $3}' \
        | sort -k2,2nr \
        | awk 'NR==1 {print $1}'
}

echo -e "${CYAN}正在检查 sing-box 最新版本...${NC}"
release_json="$(fetch_text "$API_URL")"
if [ -z "$release_json" ]; then
    echo -e "${RED}获取版本信息失败，请检查网络连通性。${NC}"
    exit 1
fi

latest_tag="$(echo "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$latest_tag" ]; then
    echo -e "${RED}解析最新版本失败，GitHub API 返回异常。${NC}"
    exit 1
fi

latest_version="${latest_tag#v}"
current_version=""
if command -v sing-box >/dev/null 2>&1; then
    current_version="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
fi

openwrt_arch="$(get_openwrt_arch)"
if [ -z "$openwrt_arch" ]; then
    echo -e "${RED}无法识别当前 OpenWrt 架构。${NC}"
    exit 1
fi

echo -e "${CYAN}当前架构: ${openwrt_arch}${NC}"
echo -e "${CYAN}当前版本: ${current_version:-未安装}${NC}"
echo -e "${CYAN}最新版本: ${latest_version}${NC}"

asset_urls="$(echo "$release_json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E '/sing-box_.*_openwrt_.*\.ipk$')"

if [ -z "$asset_urls" ]; then
    echo -e "${YELLOW}最新发布中没有 OpenWrt 安装包，取消更新。${NC}"
    exit 0
fi

asset_url="$(echo "$asset_urls" | grep -F "_openwrt_${openwrt_arch}.ipk" | head -n1)"
if [ -z "$asset_url" ]; then
    echo -e "${YELLOW}最新发布中没有匹配当前架构(${openwrt_arch})的 OpenWrt 包，取消更新。${NC}"
    exit 0
fi

if [ -n "$current_version" ] && [ "$current_version" = "$latest_version" ]; then
    echo -e "${GREEN}当前已是最新版本，无需升级。${NC}"
    exit 0
fi

pkg_name="$(basename "$asset_url")"
pkg_path="$WORK_DIR/$pkg_name"

echo -e "${CYAN}匹配到安装包: ${pkg_name}${NC}"
echo -e "${CYAN}开始下载...${NC}"
if ! download_file "$asset_url" "$pkg_path"; then
    echo -e "${RED}下载安装包失败。${NC}"
    exit 1
fi

was_running=0
if [ -f /etc/init.d/sing-box ] && /etc/init.d/sing-box status 2>/dev/null | grep -q "running"; then
    was_running=1
    /etc/init.d/sing-box stop >/dev/null 2>&1
fi

echo -e "${CYAN}正在安装 OpenWrt 包...${NC}"
if ! opkg install "$pkg_path"; then
    echo -e "${RED}opkg 安装失败，升级中止。${NC}"
    if [ "$was_running" -eq 1 ] && [ -f /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box start >/dev/null 2>&1
    fi
    exit 1
fi

if [ "$was_running" -eq 1 ] && [ -f /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box start >/dev/null 2>&1
fi

new_version="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
if [ -n "$new_version" ]; then
    echo -e "${GREEN}升级完成，当前版本: ${new_version}${NC}"
else
    echo -e "${YELLOW}升级完成，但版本校验失败，请手动执行: sing-box version${NC}"
fi
