#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
WORK_DIR="/tmp/sing-box-install.$$"
mkdir -p "$WORK_DIR" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT

proxy_url() {
    local raw="$1"
    case "$raw" in
        https://gh-proxy.com/*) echo "$raw" ;;
        *) echo "https://gh-proxy.com/$raw" ;;
    esac
}

fetch_text() {
    local url="$1"
    local body code i target proxy

    proxy="$(proxy_url "$url")"

    for target in "$proxy" "$url"; do
        if command -v curl >/dev/null 2>&1; then
            for i in 1 2 3; do
                body="$(curl -sSL -H "Accept: application/vnd.github+json" -H "User-Agent: sbshell/$i" -w $'\n%{http_code}' "$target")"
                code="${body##*$'\n'}"
                body="${body%$'\n'*}"
                if [ "$code" = "200" ] && [ -n "$body" ]; then
                    echo "$body"
                    return 0
                fi
                sleep 2
            done
        fi

        if command -v wget >/dev/null 2>&1; then
            for i in 1 2 3; do
                body="$(wget -qO- --header="Accept: application/vnd.github+json" --header="User-Agent: sbshell/$i" "$target" 2>/dev/null)"
                if [ -n "$body" ]; then
                    echo "$body"
                    return 0
                fi
                sleep 2
            done
        fi
    done

    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local i target proxy

    proxy="$(proxy_url "$url")"
    for target in "$proxy" "$url"; do
        for i in 1 2 3; do
            rm -f "$output"
            if command -v curl >/dev/null 2>&1; then
                if curl -fL --connect-timeout 10 --max-time 180 "$target" -o "$output"; then
                    return 0
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -O "$output" "$target"; then
                    return 0
                fi
            fi
            sleep 2
        done
        echo -e "${YELLOW}当前下载链路失败：$target${NC}" >&2
    done

    return 1
}

get_openwrt_arch() {
    opkg print-architecture 2>/dev/null \
        | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $2, $3}' \
        | sort -k2,2nr \
        | awk 'NR==1 {print $1}'
}

install_singbox_ipk() {
    local pkg_path="$1"
    local log="$WORK_DIR/opkg-singbox.log"

    if opkg install "$pkg_path" >"$log" 2>&1; then
        return 0
    fi

    if grep -q "pkg_hash_check_unresolved" "$log"; then
        echo -e "${YELLOW}检测到依赖解析失败，尝试 --force-depends 安装...${NC}"
        opkg install --force-depends "$pkg_path" >>"$log" 2>&1 && return 0
    fi

    cat "$log"
    return 1
}

install_official_singbox() {
    local openwrt_arch release_json latest_tag asset_urls asset_url
    local pkg_name pkg_path

    openwrt_arch="$(get_openwrt_arch)"
    if [ -z "$openwrt_arch" ]; then
        echo -e "${YELLOW}无法识别当前 OpenWrt 架构，将改用 opkg 源安装。${NC}"
        return 1
    fi

    echo "正在检查 sing-box 官方最新版本..."
    release_json="$(fetch_text "$API_URL")"
    if [ -z "$release_json" ]; then
        echo -e "${YELLOW}获取最新版本信息失败，将改用 opkg 源安装。${NC}"
        return 1
    fi

    latest_tag="$(echo "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -z "$latest_tag" ]; then
        echo -e "${YELLOW}解析最新版本失败，将改用 opkg 源安装。${NC}"
        return 1
    fi

    asset_urls="$(echo "$release_json" \
        | tr ',' '\n' \
        | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' \
        | grep -E '/sing-box_.*_openwrt_.*\.ipk$')"
    asset_url="$(echo "$asset_urls" | grep -F "_openwrt_${openwrt_arch}.ipk" | head -n1)"

    if [ -z "$asset_url" ]; then
        echo -e "${YELLOW}未找到匹配架构 ${openwrt_arch} 的官方安装包，将改用 opkg 源安装。${NC}"
        return 1
    fi

    pkg_name="$(basename "$asset_url")"
    pkg_path="$WORK_DIR/$pkg_name"

    # 官方 ipk 需要的内核模块，尽力保证存在
    opkg install kmod-nft-queue >/dev/null 2>&1

    echo -e "${CYAN}匹配到官方最新安装包: ${pkg_name}${NC}"
    echo -e "${CYAN}开始下载...${NC}"
    if ! download_file "$asset_url" "$pkg_path"; then
        echo -e "${YELLOW}下载官方安装包失败，将改用 opkg 源安装。${NC}"
        return 1
    fi

    echo -e "${CYAN}正在安装 sing-box ${latest_tag} ...${NC}"
    if ! install_singbox_ipk "$pkg_path"; then
        echo -e "${YELLOW}官方安装包安装失败，将改用 opkg 源安装。${NC}"
        return 1
    fi

    return 0
}

if command -v sing-box &> /dev/null; then
    echo -e "${CYAN}sing-box 已安装，跳过安装步骤${NC}"
else
    echo "正在更新包列表并安装依赖,请稍候..."
    opkg update >/dev/null 2>&1
    opkg install kmod-nft-tproxy >/dev/null 2>&1

    if install_official_singbox; then
        echo -e "${CYAN}sing-box 官方最新版安装成功${NC}"
    else
        echo -e "${YELLOW}改为使用 opkg 源安装 sing-box（版本可能较旧）...${NC}"
        opkg install sing-box >/dev/null 2>&1
    fi

    if command -v sing-box &> /dev/null; then
        echo -e "${CYAN}sing-box 安装成功${NC}"
        sing-box version 2>/dev/null | grep 'sing-box version' | head -n1
    else
        echo -e "${RED}sing-box 安装失败，请检查日志或网络配置${NC}"
        exit 1
    fi
fi

# 添加启动和停止命令到现有服务脚本
if [ -f /etc/init.d/sing-box ]; then
    sed -i '/start_service()/,/}/d' /etc/init.d/sing-box
    sed -i '/stop_service()/,/}/d' /etc/init.d/sing-box
fi

cat << 'EOF' >> /etc/init.d/sing-box

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
    procd_set_param respawn
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance

    /etc/sing-box/scripts/apply_firewall.sh &

}

stop_service() {
    procd_kill "$NAME" 2>/dev/null
}
EOF

chmod +x /etc/init.d/sing-box

/etc/init.d/sing-box enable
/etc/init.d/sing-box start

echo -e "${CYAN}sing-box 服务已启用并启动${NC}"
