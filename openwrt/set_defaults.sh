#!/bin/bash

DEFAULTS_FILE="/etc/sing-box/defaults.conf"

current_tproxy=$(grep '^TPROXY_SUBSCRIPTION_URL=' "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)
current_tun=$(grep '^TUN_SUBSCRIPTION_URL=' "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2-)

read -rp "请输入TProxy订阅地址: " TPROXY_SUBSCRIPTION_URL
TPROXY_SUBSCRIPTION_URL=${TPROXY_SUBSCRIPTION_URL:-$current_tproxy}

read -rp "请输入TUN订阅地址: " TUN_SUBSCRIPTION_URL
TUN_SUBSCRIPTION_URL=${TUN_SUBSCRIPTION_URL:-$current_tun}

cat > "$DEFAULTS_FILE" <<EOF
TPROXY_SUBSCRIPTION_URL=$TPROXY_SUBSCRIPTION_URL
TUN_SUBSCRIPTION_URL=$TUN_SUBSCRIPTION_URL
EOF

echo "默认配置已更新"
