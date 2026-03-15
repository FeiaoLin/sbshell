#!/bin/bash

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
WORK_DIR="/tmp/sing-box-upgrade.$$"
SINGBOX_BIN="/usr/bin/sing-box"
MODE_FILE="/etc/sing-box/mode.conf"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}閿欒: 璇蜂娇鐢?root 杩愯璇ヨ剼鏈?{NC}"
    exit 1
fi

if ! grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    echo -e "${RED}浠呮敮鎸?OpenWrt 绯荤粺鎵ц鍗囩骇銆?{NC}"
    exit 1
fi

if ! command -v opkg >/dev/null 2>&1; then
    echo -e "${RED}鏈娴嬪埌 opkg锛屾棤娉曟墽琛屽崌绾с€?{NC}"
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

pkg_installed_version() {
    local pkg="$1"
    opkg list-installed "$pkg" 2>/dev/null | awk '{print $3; exit}'
}

pkg_has_upgrade() {
    local pkg="$1"
    opkg list-upgradable 2>/dev/null | awk -v p="$pkg" '$1==p {found=1} END{exit(found?0:1)}'
}

runtime_mode() {
    grep -E '^MODE=' "$MODE_FILE" 2>/dev/null | sed 's/^MODE=//'
}

health_check() {
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

install_singbox_ipk() {
    local pkg_path="$1"
    local log="$WORK_DIR/opkg-singbox.log"

    if opkg install "$pkg_path" >"$log" 2>&1; then
        return 0
    fi

    if grep -q "pkg_hash_check_unresolved" "$log"; then
        echo -e "${YELLOW}妫€娴嬪埌渚濊禆瑙ｆ瀽澶辫触锛屽皾璇?--force-depends 缁х画瀹夎 sing-box...${NC}"
        opkg install --force-depends "$pkg_path" >>"$log" 2>&1 && return 0
    fi

    cat "$log"
    return 1
}

upgrade_kmod_queue() {
    local log="$WORK_DIR/opkg-kmod.log"
    opkg install kmod-nft-queue >"$log" 2>&1 && return 0
    cat "$log"
    return 1
}

rollback_kmod() {
    local backup_ipk="$1"
    [ -n "$backup_ipk" ] || return 1
    [ -f "$backup_ipk" ] || return 1

    echo -e "${YELLOW}姝ｅ湪鍥為€€ kmod-nft-queue...${NC}"
    opkg install --force-downgrade "$backup_ipk" >/tmp/kmod-rollback.log 2>&1
}

backup_kmod_ipk() {
    local installed_ver="$1"
    local backup_path="$WORK_DIR/kmod-nft-queue-${installed_ver}.ipk"

    [ -n "$installed_ver" ] || return 1

    (
        cd "$WORK_DIR" || exit 1
        opkg download "kmod-nft-queue=$installed_ver" >/dev/null 2>&1 || opkg download kmod-nft-queue >/dev/null 2>&1
    )

    local found
    found="$(ls "$WORK_DIR"/kmod-nft-queue*.ipk 2>/dev/null | head -n1)"
    [ -n "$found" ] || return 1

    mv "$found" "$backup_path" 2>/dev/null || cp "$found" "$backup_path"
    echo "$backup_path"
    return 0
}

prompt_rollback() {
    local target="$1"
    local answer
    read -rp "妫€娴嬪埌寮傚父锛屾槸鍚﹀洖閫€ ${target}?(y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

openwrt_arch="$(get_openwrt_arch)"
if [ -z "$openwrt_arch" ]; then
    echo -e "${RED}鏃犳硶璇嗗埆褰撳墠 OpenWrt 鏋舵瀯銆?{NC}"
    exit 1
fi

echo -e "${CYAN}姝ｅ湪鏇存柊杞欢鍖呯储寮?..${NC}"
if ! opkg update >/tmp/sbshell-opkg-update.log 2>&1; then
    echo -e "${YELLOW}opkg update 澶辫触锛屽皢缁х画浣跨敤褰撳墠绱㈠紩銆?{NC}"
fi

current_singbox_ver=""
if command -v sing-box >/dev/null 2>&1; then
    current_singbox_ver="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
fi
kmod_installed_ver="$(pkg_installed_version kmod-nft-queue)"

echo -e "${CYAN}姝ｅ湪妫€鏌?sing-box 鏈€鏂扮増鏈?..${NC}"
release_json="$(fetch_text "$API_URL")"
if [ -z "$release_json" ]; then
    echo -e "${RED}鑾峰彇鐗堟湰淇℃伅澶辫触锛岃妫€鏌ョ綉缁滆繛閫氭€с€?{NC}"
    exit 1
fi

latest_tag="$(echo "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$latest_tag" ]; then
    echo -e "${RED}瑙ｆ瀽鏈€鏂扮増鏈け璐ワ紝GitHub API 杩斿洖寮傚父銆?{NC}"
    exit 1
fi
latest_singbox_ver="${latest_tag#v}"

asset_urls="$(echo "$release_json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E '/sing-box_.*_openwrt_.*\.ipk$')"
asset_url="$(echo "$asset_urls" | grep -F "_openwrt_${openwrt_arch}.ipk" | head -n1)"

if [ -z "$asset_url" ]; then
    echo -e "${YELLOW}鏈€鏂板彂甯冧腑娌℃湁鍖归厤褰撳墠鏋舵瀯(${openwrt_arch})鐨?OpenWrt 瀹夎鍖咃紝鍙栨秷鏇存柊銆?{NC}"
    exit 0
fi

singbox_need_update=1
if [ -n "$current_singbox_ver" ] && [ "$current_singbox_ver" = "$latest_singbox_ver" ]; then
    singbox_need_update=0
fi

kmod_need_update=0
if pkg_has_upgrade kmod-nft-queue; then
    kmod_need_update=1
fi

echo -e "${CYAN}褰撳墠鏋舵瀯: ${openwrt_arch}${NC}"
echo -e "${CYAN}sing-box: ${current_singbox_ver:-鏈畨瑁厎 -> ${latest_singbox_ver}${NC}"
echo -e "${CYAN}kmod-nft-queue: ${kmod_installed_ver:-鏈畨瑁厎${NC}"
if [ "$kmod_need_update" -eq 0 ]; then
    echo -e "${CYAN}kmod-nft-queue 鏃犲彲鐢ㄦ洿鏂?{NC}"
else
    echo -e "${CYAN}kmod-nft-queue 妫€娴嬪埌鍙敤鏇存柊${NC}"
fi

# 5. 鍧囨棤鏇存柊
if [ "$singbox_need_update" -eq 0 ] && [ "$kmod_need_update" -eq 0 ]; then
    echo -e "${GREEN}sing-box 涓?kmod-nft-queue 鍧囦负鏈€鏂帮紝鏃犻渶鎿嶄綔銆?{NC}"
    exit 0
fi

was_running=0
if [ -f /etc/init.d/sing-box ] && /etc/init.d/sing-box status 2>/dev/null | grep -q "running"; then
    was_running=1
    /etc/init.d/sing-box stop >/dev/null 2>&1
fi

singbox_backup=""
if [ "$singbox_need_update" -eq 1 ] && [ -f "$SINGBOX_BIN" ]; then
    singbox_backup="$WORK_DIR/sing-box.backup"
    cp "$SINGBOX_BIN" "$singbox_backup"
fi

kmod_backup=""
if [ "$kmod_need_update" -eq 1 ]; then
    # 4. kmod-only 闇€瑕佸彲鍥為€€淇濋殰
    if [ "$singbox_need_update" -eq 0 ]; then
        kmod_backup="$(backup_kmod_ipk "$kmod_installed_ver")"
        if [ -z "$kmod_backup" ]; then
            echo -e "${RED}kmod-nft-queue 瀛樺湪鏇存柊锛屼絾鏃犳硶鍑嗗鍥為€€鍖咃紝宸蹭腑姝㈠崌绾т互閬垮厤涓嶅彲鍥為€€椋庨櫓銆?{NC}"
            [ "$was_running" -eq 1 ] && /etc/init.d/sing-box start >/dev/null 2>&1
            exit 1
        fi
    fi

    echo -e "${CYAN}姝ｅ湪鏇存柊 kmod-nft-queue...${NC}"
    if ! upgrade_kmod_queue; then
        echo -e "${RED}kmod-nft-queue 鏇存柊澶辫触銆?{NC}"
        [ "$was_running" -eq 1 ] && /etc/init.d/sing-box start >/dev/null 2>&1
        exit 1
    fi
fi

if [ "$singbox_need_update" -eq 1 ]; then
    pkg_name="$(basename "$asset_url")"
    pkg_path="$WORK_DIR/$pkg_name"

    echo -e "${CYAN}鍖归厤鍒?sing-box 瀹夎鍖? ${pkg_name}${NC}"
    echo -e "${CYAN}寮€濮嬩笅杞?..${NC}"
    if ! download_file "$asset_url" "$pkg_path"; then
        echo -e "${RED}涓嬭浇 sing-box 瀹夎鍖呭け璐ャ€?{NC}"
        [ "$was_running" -eq 1 ] && /etc/init.d/sing-box start >/dev/null 2>&1
        exit 1
    fi

    echo -e "${CYAN}姝ｅ湪瀹夎 sing-box...${NC}"
    if ! install_singbox_ipk "$pkg_path"; then
        echo -e "${RED}sing-box 瀹夎澶辫触銆?{NC}"
        if [ -n "$singbox_backup" ] && [ -f "$singbox_backup" ]; then
            if prompt_rollback "sing-box"; then
                cp "$singbox_backup" "$SINGBOX_BIN"
                chmod 755 "$SINGBOX_BIN"
                echo -e "${YELLOW}宸插洖閫€鍒板崌绾у墠 sing-box 浜岃繘鍒躲€?{NC}"
            else
                echo -e "${YELLOW}宸茶烦杩?sing-box 鍥為€€銆?{NC}"
            fi
        fi
        [ "$was_running" -eq 1 ] && /etc/init.d/sing-box start >/dev/null 2>&1
        exit 1
    fi
fi

if [ "$was_running" -eq 1 ] && [ -f /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box start >/dev/null 2>&1
fi

new_singbox_ver="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
final_kmod_upgradable=1
if pkg_has_upgrade kmod-nft-queue; then
    final_kmod_upgradable=1
else
    final_kmod_upgradable=0
fi

health_ok=1
if [ "$was_running" -eq 1 ]; then
    if health_check; then
        health_ok=0
    fi
fi

# 3. sing-box 鏇存柊鍚庝笉鍖归厤锛屽洖閫€ sing-box
if [ "$singbox_need_update" -eq 1 ] && [ "$new_singbox_ver" != "$latest_singbox_ver" ]; then
    echo -e "${RED}sing-box 鐩爣鐗堟湰 ${latest_singbox_ver} 鏈敓鏁堬紝褰撳墠 ${new_singbox_ver:-鏈煡}銆?{NC}"
    if [ -n "$singbox_backup" ] && [ -f "$singbox_backup" ]; then
        if prompt_rollback "sing-box"; then
            cp "$singbox_backup" "$SINGBOX_BIN"
            chmod 755 "$SINGBOX_BIN"
            [ "$was_running" -eq 1 ] && /etc/init.d/sing-box restart >/dev/null 2>&1
            echo -e "${YELLOW}宸插洖閫€鍒板崌绾у墠 sing-box 鐗堟湰銆?{NC}"
        else
            echo -e "${YELLOW}宸茶烦杩?sing-box 鍥為€€銆?{NC}"
        fi
    fi
    exit 1
fi

# 4. kmod-only 鏇存柊鍚庤繍琛屽け璐ワ紝鍥為€€ kmod
if [ "$kmod_need_update" -eq 1 ] && [ "$singbox_need_update" -eq 0 ]; then
    if [ "$health_ok" -ne 0 ]; then
        echo -e "${RED}kmod-nft-queue 鏇存柊鍚庤繍琛屽仴搴锋鏌ュけ璐ャ€?{NC}"
        if prompt_rollback "kmod-nft-queue"; then
            if rollback_kmod "$kmod_backup"; then
                [ "$was_running" -eq 1 ] && /etc/init.d/sing-box restart >/dev/null 2>&1
                echo -e "${YELLOW}宸插洖閫€ kmod-nft-queue銆?{NC}"
            fi
        else
            echo -e "${YELLOW}宸茶烦杩?kmod-nft-queue 鍥為€€銆?{NC}"
        fi
        exit 1
    fi
fi

# 1 / 2. 升级并可用
if [ "$was_running" -eq 1 ] && [ "$health_ok" -ne 0 ]; then
    echo -e "${RED}鍗囩骇鍚庢湇鍔″仴搴锋鏌ュけ璐ワ紝璇锋墽琛? logread -e sing-box${NC}"
    exit 1
fi

echo -e "${GREEN}鍗囩骇瀹屾垚銆傚綋鍓?sing-box 鐗堟湰: ${new_singbox_ver:-鏈煡}${NC}"
if [ "$kmod_need_update" -eq 1 ]; then
    if [ "$final_kmod_upgradable" -eq 0 ]; then
        echo -e "${GREEN}kmod-nft-queue 宸叉洿鏂般€?{NC}"
    else
        echo -e "${YELLOW}kmod-nft-queue 鍙兘浠嶆湁鍙崌绾ч」锛岃鎵嬪姩纭銆?{NC}"
    fi
fi

exit 0
