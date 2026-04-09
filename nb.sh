#!/bin/bash
set -e

# --- 0. 环境准备与强制静默 ---
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt install jq socat curl wget openssl tar grep chrony qrencode -y
ufw disable >/dev/null 2>&1 || true
iptables -P INPUT ACCEPT && iptables -F

# --- 1. 内核优化 (MTU 探测 + BBR/FQ) ---
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

# --- 2. 路径与架构检测 ---
mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"
cpu=$(uname -m); [ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"

# --- 3. 核心安装与还原逻辑 ---
echo "==============================================="
echo "  TikTok 矩阵环境-WebRTC强力拦截版 V22.3"
echo "==============================================="
echo " 1. 全新安装 (随机域名 + 随机参数)"
echo " 2. 参数还原 (手动输入旧参数)"
read -p "请选择 [1-2]: " MODE

if [ ! -f "/etc/s-box/sing-box" ]; then
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-$cpu.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*
fi

if [ "$MODE" == "2" ]; then
    read -p "输入 UUID: " uuid
    read -p "输入 Public-Key: " public_key
    read -p "输入 Private-Key: " private_key
    read -p "输入 Short-ID: " short_id
    read -p "输入伪装域名: " RAND_DOMAIN
    RAND_PORT=443
else
    # V14.0 随机域名池逻辑
    domains=("www.microsoft.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com" "www.speedtest.net" "www.yahoo.com" "www.amd.com")
    RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
    uuid=$(/etc/s-box/sing-box generate uuid)
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    RAND_PORT=443
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public_key=$(grep -i "public" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    rm -f /tmp/sb_keys.txt
fi

echo "$public_key" > /etc/s-box/public.key

# --- 4. 写入服务端配置 (合体勇哥 WebRTC 拦截逻辑) ---
cat > $CONF_PATH <<JSON
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": $RAND_PORT,
    "sniff": true,
    "sniff_override_destination": true,
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
      { "network": "udp", "outbound": "block" },
      { "port": [3478, 19302, 19305], "outbound": "block" }
    ]
  }
}
JSON

# --- 5. 系统服务自启 ---
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box

# --- 6. 快捷 nb 命令 (满血参数输出) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 icanhazip.com)
    u=$(jq -r '.inbounds[0].users[0].uuid' $CP)
    p=$(jq -r '.inbounds[0].listen_port' $CP)
    sn=$(jq -r '.inbounds[0].tls.server_name' $CP)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CP)
    pb=$(cat /etc/s-box/public.key)
    link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP"

    echo "==============================================="
    echo "📋 Nikki / Clash 完整参数 (WebRTC 已物理封杀)"
    echo "==============================================="
    printf "  - name: \"TK-%s\"\n" "$IP"
    printf "    type: vless\n"
    printf "    server: %s\n" "$IP"
    printf "    port: %d\n" "$p"
    printf "    uuid: %s\n" "$u"
    printf "    udp: false          # <--- WebRTC 核心封杀点\n"
    printf "    tls: true\n"
    printf "    flow: xtls-rprx-vision\n"
    printf "    servername: %s\n" "$sn"
    printf "    reality-opts:\n"
    printf "      public-key: %s\n" "$pb"
    printf "      short-id: %s\n" "$sid"
    printf "    client-fingerprint: safari\n"
    echo "-----------------------------------------------"
    echo "🔗 VLESS 链接 / 📱 二维码"
    echo -e "\033[32m$link\033[0m"
    echo "-----------------------------------------------"
    qrencode -t ansiutf8 "$link"
    echo "==============================================="
}

rm -f /usr/local/bin/nb
cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
chmod +x /usr/local/bin/nb
/usr/local/bin/nb
