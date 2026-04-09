#!/bin/bash

# --- 1. 自动安装基础组件 ---
for pkg in qrencode jq curl openssl; do
    if ! command -v $pkg >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then
            apt update -y && apt install -y $pkg > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y $pkg > /dev/null 2>&1
        fi
    fi
done

# --- 2. 路径检测逻辑 ---
detect_path() {
    possible_paths=("/etc/s-box/sb.json" "/etc/v2ray-agent/sing-box/conf/config.json")
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return
        fi
    done
}

CONF_PATH=$(detect_path)

# --- 3. 如果没安装，则调用勇哥安装脚本 ---
if [ -z "$CONF_PATH" ]; then
    echo "⚠️ 检测到尚未安装 Sing-box，正在为您调取勇哥安装程序..."
    sleep 2
    # 调用勇哥官方安装脚本
    bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
    
    # 安装完重新检测路径
    CONF_PATH=$(detect_path)
    if [ -z "$CONF_PATH" ]; then
        echo "❌ 安装似乎未成功，请检查上方安装日志。"
        exit 1
    fi
fi

# --- 4. 定义显示函数 (nb) ---
nb_info() {
    CP=$(detect_path) # 动态获取，防止路径变化
    IP=$(curl -s -4 icanhazip.com)
    UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // .users[0].id' $CP | head -n 1)
    PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // .port' $CP | head -n 1)
    S_NAME=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name // .tls.reality.handshake.server' $CP | head -n 1)
    S_ID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' $CP | head -n 1)
    [ -f "/etc/s-box/public.key" ] && PUB_KEY=$(cat /etc/s-box/public.key) || PUB_KEY="需在配置目录确认"

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${S_NAME}&fp=safari&pbk=${PUB_KEY}&sid=${S_ID}&type=tcp&headerType=none#TK-NB-PureTCP"

    clear
    echo "==============================================="
    echo "🌟 TikTok 纯 TCP 运营环境 (nb)"
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

# --- 5. 写入永久 nb 命令 ---
if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f detect_path)
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

# --- 6. 执行环境加固逻辑 ---
echo "正在为您进行 TikTok 运营级环境加固..."

# 随机化特征
domains=("www.microsoft.com" "www.lovelive-anime.jp" "www.speedtest.net" "www.yahoo.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH

# 拦截 WebRTC (STUN)
if ! grep -q "stun" $CONF_PATH; then
    sed -i '/"rules": \[/a \        { "protocol": ["stun"], "outbound": "block" },' $CONF_PATH
fi

# 强制 Safari 指纹
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

# 重启服务
systemctl restart sing-box

# --- 7. 完成展示 ---
nb_info
echo "✅ 全部搞定！下次登录直接输入 nb 即可查看此信息。"
