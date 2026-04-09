#!/bin/bash
set -e

# --- 1. 依赖与内核优化 ---
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt install jq socat curl wget openssl tar grep chrony qrencode -y
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
timedatectl set-timezone UTC
systemctl restart chrony
sed -i '/net./d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
CONF
sysctl -p >/dev/null 2>&1

# --- 2. 路径检测 ---
mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"
cpu=$(uname -m); [ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"

# --- 3. 核心安装/还原逻辑 ---
echo "==============================================="
echo "  TikTok 矩阵环境一键部署/还原脚本 V22.0"
echo "==============================================="
echo " 1. 全新安装 (所有参数随机生成)"
echo " 2. 参数还原 (手动输入旧 UUID/公钥/ShortID)"
read -p "请选择 [1-2]: " MODE

if [ "$MODE" == "2" ]; then
    read -p "输入 UUID: " uuid
    read -p "输入 Public-Key: " public_key
    read -p "输入 Private-Key: " private_key
    read -p "输入 Short-ID: " short_id
    read -p "输入伪装域名 (如 www.samsung.com): " RAND_DOMAIN
    RAND_PORT=443
else
    # 全新安装流程
    [ ! -f "/etc/s-box/sing-box" ] && {
        wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-$cpu.tar.gz"
        tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
        mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
        chmod +x /etc/s-box/sing-box
        rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*
    }
    uuid=$(/etc/s-box/sing-box generate uuid)
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    RAND_PORT=443
    RAND_DOMAIN="www.microsoft.com"
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public_key=$(grep -i "public" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    rm -f /tmp/sb_keys.txt
fi

echo "$public_key" > /etc/s-box/public.key

# --- 4. 写入配置 (内嵌 WebRTC 强力拦截) ---
cat > $CONF_PATH <<JSON
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": $RAND_PORT,
    "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$RAND_DOMAIN",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$RAND_DOMAIN", "server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$short_id"]
      }
    }
  }],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "rules": [
      { "protocol": ["stun"], "outbound": "block" },
      { "network": "udp", "outbound": "block" }
    ]
  }
}
JSON

# --- 5. 系统服务 ---
[ ! -f /etc/systemd/system/sing-box.service ] && {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable sing-box
}
systemctl restart sing-box

# --- 6. 快捷 nb 命令 (强制覆盖) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 icanhazip.com)
    u=$(jq -r '.inbounds[0].users[0].uuid' $CP)
    p=$(jq -r '.inbounds[0].listen_port' $CP)
    sn=$(jq -r '.inbounds[0].tls.server_name' $CP)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CP)
    pb=$(cat /etc/s-box/public.key)
    
    echo "==============================================="
    echo "🚀 TikTok 矩阵专用配置 (nb 命令)"
    echo "==============================================="
    printf "  - name: \"TK-%s\"\n" "$IP"
    printf "    type: vless\n"
    printf "    server: %s\n" "$IP"
    printf "    port: %d\n" "$p"
    printf "    uuid: %s\n" "$u"
    printf "    udp: false          # <--- WebRTC 已锁死\n"
    printf "    tls: true\n"
    printf "    flow: xtls-rprx-vision\n"
    printf "    servername: %s\n" "$sn"
    printf "    reality-opts:\n"
    printf "      public-key: %s\n" "$pb"
    printf "      short-id: %s\n" "$sid"
    printf "    client-fingerprint: safari\n"
    echo "-----------------------------------------------"
    echo -e "VLESS 链接: \033[32mvless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP\033[0m"
}

rm -f /usr/local/bin/nb
cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
chmod +x /usr/local/bin/nb

# 最后跑一遍显示
/usr/local/bin/nb
