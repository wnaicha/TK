#!/bin/bash

# =========================================================
# 1. 基础依赖与环境自动安装
# =========================================================
for pkg in qrencode jq curl openssl wget tar; do
    if ! command -v $pkg >/dev/null 2>&1; then
        apt update -y && apt install -y $pkg > /dev/null 2>&1
    fi
done

mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"

# =========================================================
# 2. 核心功能函数：显示二维码与完整参数 (nb)
# =========================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    if [ ! -f "$CP" ]; then
        echo "❌ 错误: 未检测到配置文件，请先运行脚本完成安装！"
        return
    fi

    # 抓取公网 IP
    IP=$(curl -s4m 5 icanhazip.com || curl -s4m 5 api.ipify.org || echo "IP获取失败")
    
    # 提取参数
    UUID=$(grep -oE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' "$CP" | head -n 1)
    PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "$CP" | head -n 1)
    S_NAME=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name' "$CP" | head -n 1)
    S_ID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' "$CP" | head -n 1)
    PUB_KEY=$(cat /etc/s-box/public.key 2>/dev/null || echo "需手动确认")

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${S_NAME}&fp=safari&pbk=${PUB_KEY}&sid=${S_ID}&type=tcp&headerType=none#TK-NB-PureTCP"

    echo "==============================================="
    echo "🌟 TikTok 纯 TCP 运营环境 (nb 命令已就绪)"
    echo "==============================================="
    echo "🚀 VLESS 订阅二维码:"
    echo "$VLESS_LINK" | qrencode -t UTF8
    echo ""
    echo "🚀 VLESS 链接:"
    echo -e "\033[33m${VLESS_LINK}\033[0m"
    echo ""
    echo "📦 Nikki / Clash 完整参数 (请对照录入):"
    echo "-----------------------------------------------"
    echo "  server: $IP"
    echo "  port: $PORT"
    echo "  uuid: $UUID"
    echo "  flow: xtls-rprx-vision"
    echo "  udp: false              # <--- 封杀 WebRTC 核心"
    echo "  tls: true               # <--- Reality 必须开启"
    echo "  servername: $S_NAME"
    echo "  reality-opts:"
    echo "    public-key: $PUB_KEY"
    echo "    short-id: $S_ID"
    echo "  client-fingerprint: safari"
    echo "-----------------------------------------------"
    echo "✅ 提示：下次登录直接输入 nb 即可查看此界面"
}

# =========================================================
# 3. 永久化 nb 命令
# =========================================================
if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

# =========================================================
# 4. 安装逻辑：如果文件不存在，执行完整安装流程
# =========================================================
if [ ! -f "$CONF_PATH" ]; then
    echo "🚀 未检测到配置，正在开始全新整合安装..."
    
    # 自动识别架构
    arch=$(uname -m)
    case $arch in
        x86_64) cpu="amd64" ;;
        aarch64) cpu="arm64" ;;
        *) echo "不支持的架构"; exit 1 ;;
    esac

    # 下载最新 Sing-box 内核 (无需调用外部脚本，直接下载)
    sbver=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${sbver}/sing-box-${sbver}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*

    # 生成 Reality 密钥对和必备参数
    UUID=$(/etc/s-box/sing-box generate uuid)
    RAND_PORT=$(shuf -i 20000-60000 -n 1)
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key" > /etc/s-box/public.key
    short_id=$(openssl rand -hex 4)

    # 写入完整的 纯TCP+勇哥拦截规则 配置文件
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

    # 写入系统服务
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
    echo "✅ 安装完成！"
fi

# =========================================================
# 5. 特征加固 (每次运行都会更新域名和ID)
# =========================================================
echo "执行动态加固与指纹锁定..."
domains=("www.microsoft.com" "www.lovelive-anime.jp" "www.speedtest.net" "www.yahoo.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

systemctl restart sing-box

# 显示结果
nb_info
