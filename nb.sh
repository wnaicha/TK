#!/bin/bash
set -e

# --- 1. 环境准备 ---
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt install jq socat curl wget openssl tar grep chrony qrencode -y

# 基础设置与内核优化
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
timedatectl set-timezone UTC
systemctl restart chrony
ufw disable >/dev/null 2>&1 || true
iptables -P INPUT ACCEPT && iptables -F

sed -i '/net./d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
CONF
sysctl -p >/dev/null 2>&1

# --- 2. 路径与架构准备 ---
mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"
cpu=$(uname -m)
[ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"
sbver="1.10.7"

# --- 3. 核心显示函数 (nb) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    [ ! -f "$CP" ] && return

    IP=$(curl -s4m5 icanhazip.com)
    # 使用 jq 提取当前配置中的真实变量
    u=$(jq -r '.inbounds[0].users[0].uuid' $CP)
    p=$(jq -r '.inbounds[0].listen_port' $CP)
    sn=$(jq -r '.inbounds[0].tls.server_name' $CP)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CP)
    pb=$(cat /etc/s-box/public.key 2>/dev/null || echo "key_err")

    VLESS_LINK="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP"

    echo "======================================================"
    echo "🚀 TikTok 矩阵动态随机版 (nb) 部署成功！"
    echo "======================================================"
    echo "VLESS 分享链接 (Shadowrocket):"
    echo -e "\033[33m$VLESS_LINK\033[0m"
    echo ""
    echo "VLESS 订阅二维码:"
    echo "$VLESS_LINK" | qrencode -t UTF8
    echo ""
    echo "Nikki / Clash 配置参数 (标准格式):"
    echo "------------------------------------------------------"
    printf "  - name: \"TK-%s\"\n" "$IP"
    printf "    type: vless\n"
    printf "    server: %s\n" "$IP"
    printf "    port: %s\n" "$p"
    printf "    uuid: %s\n" "$u"
    printf "    udp: false\n"
    printf "    tls: true\n"
    printf "    flow: xtls-rprx-vision\n"
    printf "    servername: %s\n" "$sn"
    printf "    reality-opts:\n"
    printf "      public-key: %s\n" "$pb"
    printf "      short-id: %s\n" "$sid"
    printf "    client-fingerprint: safari\n"
    echo "------------------------------------------------------"
    echo "✅ 提示：下次登录输入 nb 即可显示此界面"
}

# --- 4. 安装/更新逻辑 (这里包含了你找的那两行代码) ---
if [ ! -f "/etc/s-box/sing-box" ]; then
    echo "正在安装 Sing-box 内核..."
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${sbver}/sing-box-${sbver}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*
fi

# --- 5. 动态生成随机特征 (核心对齐) ---
# 这就是你要的那两行代码，用内核生成最纯正的参数
uuid=$(/etc/s-box/sing-box generate uuid)
short_id=$(/etc/s-box/sing-box generate rand --hex 4)

# 随机伪装域名
domains=("www.microsoft.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com" "www.speedtest.net")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}

# 密钥对生成
if [ ! -f "$CONF_PATH" ]; then
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    pri=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    pub=$(grep -i "public" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    echo "$pub" > /etc/s-box/public.key
    rm -f /tmp/sb_keys.txt
else
    # 如果已存在，从配置提取私钥防止变动
    pri=$(jq -r '.inbounds[0].tls.reality.private_key' $CONF_PATH)
fi

# --- 6. 写入/更新配置文件 ---
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
      { "protocol": ["stun"], "outbound": "block" },
      { "network": "udp", "outbound": "block" }
    ]
  }
}
JSON

# --- 7. 系统服务管理与快捷键 ---
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

if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

systemctl restart sing-box
nb_info
