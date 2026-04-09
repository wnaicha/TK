#!/bin/bash
set -e

# --- 1. 基础环境与加速 ---
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt install jq socat curl wget openssl tar grep chrony qrencode -y
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
timedatectl set-timezone UTC
systemctl restart chrony

# 内核加速优化 (降低重传率)
sed -i '/net./d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
CONF
sysctl -p >/dev/null 2>&1

# --- 2. 路径与变量 ---
mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"
cpu=$(uname -m); [ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"
sbver="1.10.7"

# --- 3. 核心显示函数 (强制输出并高亮 UDP 状态) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    [ ! -f "$CP" ] && return
    IP=$(curl -s4m5 icanhazip.com)
    u=$(jq -r '.inbounds[0].users[0].uuid' $CP)
    p=$(jq -r '.inbounds[0].listen_port' $CP)
    sn=$(jq -r '.inbounds[0].tls.server_name' $CP)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CP)
    pb=$(cat /etc/s-box/public.key 2>/dev/null || echo "key_err")

    echo "======================================================"
    echo "🌟 TikTok 矩阵神机部署成功！(WebRTC 已精准封杀)"
    echo "======================================================"
    echo "Nikki / Clash 参数 (复制到配置文件):"
    echo "------------------------------------------------------"
    printf "  - name: \"TK-%s\"\n" "$IP"
    printf "    type: vless\n"
    printf "    server: %s\n" "$IP"
    printf "    port: %s\n" "$p"
    printf "    uuid: %s\n" "$u"
    printf "    \033[41;37mudp: false\033[0m          # <--- WebRTC 探测阀门：已永久关闭\n"
    printf "    tls: true\n"
    printf "    flow: xtls-rprx-vision\n"
    printf "    servername: %s\n" "$sn"
    printf "    reality-opts:\n"
    printf "      public-key: %s\n" "$pb"
    printf "      short-id: %s\n" "$sid"
    printf "    client-fingerprint: safari\n"
    echo "------------------------------------------------------"
    echo -e "VLESS 链接: \033[32mvless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP\033[0m"
    echo "======================================================"
}

# --- 4. 强制重写快捷命令 ---
rm -f /usr/local/bin/nb
cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
chmod +x /usr/local/bin/nb

# --- 5. 安装内核 ---
if [ ! -f "/etc/s-box/sing-box" ]; then
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${sbver}/sing-box-${sbver}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*
fi

# --- 6. 生成核心参数 ---
uuid=$(/etc/s-box/sing-box generate uuid)
short_id=$(/etc/s-box/sing-box generate rand --hex 4)
domains=("www.microsoft.com" "www.samsung.com" "www.nvidia.com" "www.speedtest.net")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}

if [ ! -f "$CONF_PATH" ]; then
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    pri=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    pub=$(grep -i "public" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    echo "$pub" > /etc/s-box/public.key
    rm -f /tmp/sb_keys.txt
else
    pri=$(jq -r '.inbounds[0].tls.reality.private_key' $CONF_PATH)
fi

# --- 7. 写入配置文件 (核心：WebRTC 探测拦截逻辑) ---
cat > $CONF_PATH <<JSON
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": 443,
    "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$RAND_DOMAIN",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$RAND_DOMAIN", "server_port": 443},
        "private_key": "$pri",
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
      { "protocol": ["stun"], "outbound": "block" },    // 1. 拦截 STUN 协议 (WebRTC 核心)
      { "network": "udp", "outbound": "block" },      // 2. 封杀所有 UDP (WebRTC 路径)
      { "port": [3478, 19302], "outbound": "block" }  // 3. 封锁常用 WebRTC 端口
    ]
  }
}
JSON

# --- 8. 重启并展示 ---
if [ ! -f /etc/systemd/system/sing-box.service ]; then
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
fi

systemctl restart sing-box
/usr/local/bin/nb
