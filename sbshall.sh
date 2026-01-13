#!/bin/bash
# 定义主脚本的下载URL
OPENWRT_MAIN_SCRIPT_URL="https://gh-proxy.com/https://raw.githubusercontent.com/qljsyph/sbshell/refs/heads/main/openwrt/menu.sh"
 
# 脚本下载目录
SCRIPT_DIR="/etc/sing-box/scripts"

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 检查系统是否支持
if [[ "$(uname -s)" != "Linux" ]]; then
    echo -e "${RED}当前系统不支持运行此脚本。${NC}"
    exit 1
fi

# 检查发行版并下载相应的主脚本
if grep -qi 'openwrt' /etc/os-release; then
    echo -e "${GREEN}系统为OpenWRT,支持运行此脚本。${NC}"
    MAIN_SCRIPT_URL="$OPENWRT_MAIN_SCRIPT_URL"
    DEPENDENCIES=("nftables")

    # 检查并安装缺失的依赖项
    for DEP in "${DEPENDENCIES[@]}"; do
        if [ "$DEP" == "nftables" ]; then
            CHECK_CMD="nft --version"
        fi

        if ! $CHECK_CMD &> /dev/null; then
            echo -e "${RED}$DEP 未安装。${NC}"
            read -rp "是否安装 $DEP?(y/n): " install_dep
            if [[ "$install_dep" =~ ^[Yy]$ ]]; then
                opkg update
                opkg install "$DEP"
                if ! $CHECK_CMD &> /dev/null; then
                    echo -e "${RED}安装 $DEP 失败，请手动安装 $DEP 并重新运行此脚本。${NC}"
                    exit 1
                fi
                echo -e "${GREEN}$DEP 安装成功。${NC}"
            else
                echo -e "${RED}由于未安装 $DEP,脚本无法继续运行。${NC}"
                exit 1
            fi
        fi
    done
else
    echo -e "${RED}当前系统不是OpenWRT,不支持运行此脚本。${NC}"
    exit 1
fi

# 确保脚本目录存在并设置权限
mkdir -p "$SCRIPT_DIR"

# 下载并执行主脚本
curl -s -o "$SCRIPT_DIR/menu.sh" "$MAIN_SCRIPT_URL"

echo -e "${GREEN}脚本下载中,请耐心等待...${NC}"
echo -e "${YELLOW}注意:安装更新singbox尽量使用代理环境,运行singbox切记关闭代理!${NC}"

if ! [ -f "$SCRIPT_DIR/menu.sh" ]; then
    echo -e "${RED}下载主脚本失败,请检查网络连接。${NC}"
    exit 1
fi

chmod +x "$SCRIPT_DIR/menu.sh"
bash "$SCRIPT_DIR/menu.sh"
