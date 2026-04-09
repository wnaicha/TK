#!/bin/bash

# --- 1. 自动安装基础组件 ---
for pkg in qrencode jq curl openssl wget tar; do
    if ! command -v $pkg >/dev/null 2>&1; then
        apt update -y && apt install -y $pkg > /dev/null 2>&1
    fi
done

mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"

# --- 2. 增强版显示函数 (强制抓取所有漏掉的参数) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    [ ! -f "$CP" ] && echo "❌ 错误: 未检测到配置文件" && return

    # 1. 抓取公网 IP (多平台重试)
    IP=$(curl -s4m 5 icanhazip.com || curl -s4m 5 api.ipify.org || echo "IP获取失败")
    
    # 2. 暴力抓取 UUID (不分层级，只要是 vless 里的 uuid 就拿走)
    UUID=$(grep -oE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' "$CP" | head -n 1)
    
    # 3. 抓取端口
    PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "$CP" | head -n 1)
    [ "$PORT" == "null" ] && PORT=$(grep -oP '"listen_port":\s*\K[0-9]+' "$CP" | head -n 1)
    
    # 4. 抓取域名
    S_NAME=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name' "$CP" | head -n 1)
    [ "$S_NAME" == "null" ] && S_NAME=$(grep -oP '"server_name":\s*"\K[^"]+' "$CP" | head -n 1)
    
    # 5. 抓取 ShortID
    S_ID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' "$CP" | head -n 1)
    [ "$S_ID" == "null" ] && S_ID=$(grep -oP '"short_id":\s*\["\K[^"]+' "$CP" | head -n 1)
    
    # 6. 获取公钥
    if [ -f "/etc/s-box/public.key" ]; then
        PUB_KEY=$(cat /etc/s-box/public.key)
    else
        PUB_KEY=$(grep -oP '"private_key":\s*"\K[^"]+' "$CP" | head -n 1) # 备选抓取
    fi

    # 拼接 VLESS 链接
    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${S_NAME}&fp=safari&pbk=${PUB_KEY}&sid=${S_ID}&type=tcp&headerType=none#TK-Pure-TCP"

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
    echo "✅ 提示：下次登录直接输入 nb 即可回显此界面"
}

# --- 3. 永久化 nb 命令 ---
if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

# --- 4. 安装与加固逻辑 (如果配置文件不存在则安装) ---
if [ ! -f "$CONF_PATH" ]; then
    # ... (此处的安装代码与前一条回复保持一致，下载内核、生成配置) ...
    # 为了缩短回复，此处省略具体下载步骤，请确保使用之前给你的整合版完整安装逻辑
    echo "首次安装中..."
    # [此处放之前的安装逻辑代码]
fi

# --- 5. 动态特征更新 ---
echo "执行动态加固..."
domains=("www.microsoft.com" "www.speedtest.net" "www.cloudflare.com" "www.yahoo.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

systemctl restart sing-box

# --- 6. 执行最终显示 ---
nb_info
