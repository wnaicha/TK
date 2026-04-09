#!/bin/bash

# =========================================================
# 1. 基础依赖与环境准备
# =========================================================
for pkg in qrencode jq curl openssl wget tar; do
    if ! command -v $pkg >/dev/null 2>&1; then
        apt update -y && apt install -y $pkg > /dev/null 2>&1
    fi
done

mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"

# =========================================================
# 2. 核心功能函数：显示二维码与Nikki参数 (nb)
# =========================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    [ ! -f "$CP" ] && echo "❌ 错误: 未检测到配置文件" && return

    IP=$(curl -s -4 icanhazip.com)
    UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // .users[0].id' $CP | head -n 1)
    PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // .port' $CP | head -n 1)
    S_NAME=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name // .tls.reality.handshake.server' $CP | head -n 1)
    S_ID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' $CP | head -n 1)
    PUB_KEY=$(cat /etc/s-box/public.key 2>/dev/null || echo "需在配置目录确认")

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${S_NAME}&fp=safari&pbk=${PUB_KEY}&sid=${S_ID}&type=tcp&headerType=none#TK-NB-PureTCP"

    echo "==============================================="
    echo "🌟 TikTok 纯 TCP 运营环境 (nb 命令)"
    echo "==============================================="
    echo "🚀 VLESS 订阅二维码:"
    echo "$VLESS_LINK" | qrencode -t UTF8
    echo ""
    echo "🚀 VLESS 链接:"
    echo -e "\033[33m${VLESS_LINK}\033[0m"
    echo ""
    echo "📦 Nikki / Clash 专用参数:"
    echo "-----------------------------------------------"
    echo "  udp: false              # <--- 封杀 WebRTC"
    echo "  tls: true"
    echo "  flow: xtls-rprx-vision"
    echo "  servername: $S_NAME"
    echo "  reality-opts:"
    echo "    public-key: $PUB_KEY"
    echo "    short-id: $S_ID"
    echo "  client-fingerprint: safari"
    echo "-----------------------------------------------"
}

# =========================================================
# 3. 安装逻辑：如果没装就执行整合的安装流程
# =========================================================
if [ ! -f "$CONF_PATH" ]; then
    echo "🚀 正在开始整合安装流程..."
    
    # 提取系统架构
    arch=$(uname -m)
    case $arch in
        x86_64) cpu="amd64" ;;
        aarch64) cpu="arm64" ;;
        *) echo "不支持的架构"; exit 1 ;;
    esac

    # 下载最新 Sing-box 内核
    sbcore=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
    wget -O /etc/s-box/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v$sbcore/sing-box-$sbcore-linux-$cpu.tar.gz
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-$sbcore-linux-$cpu/sing-box /etc/s-box/
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-$sbcore-linux-$cpu

    # 生成密钥对与基础变量
    UUID=$(/etc/s-box/sing-box generate uuid)
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key" > /etc/s-box/public.key
    short_id=$(openssl rand -hex 4)
    RAND_PORT=$(shuf -i 10000-65535 -n 1)

    # 写入整合后的配置文件 (含勇哥拦截规则 + Safari指纹)
    cat > $CONF_PATH <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $RAND_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.microsoft.com", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "protocol": ["stun"], "outbound": "block" },
      { "network": "udp", "outbound": "block" }
    ]
  }
}
EOF

    # 配置系统服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
fi

# =========================================================
# 4. 加固逻辑：每次运行都会执行的动态特征更新
# =========================================================
echo "正在执行动态加固与指纹锁定..."
domains=("www.microsoft.com" "www.lovelive-anime.jp" "www.speedtest.net" "www.yahoo.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

# 动态换肤
sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH
# 强制Safari指纹对齐
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

systemctl restart sing-box

# =========================================================
# 5. 永久化 nb 命令与首次展示
# =========================================================
if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

nb_info
