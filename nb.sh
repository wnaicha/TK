#!/bin/bash

# --- 1. 自动安装依赖 ---
for pkg in qrencode jq curl; do
    if ! command -v $pkg >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then
            apt update -y && apt install -y $pkg > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y $pkg > /dev/null 2>&1
        fi
    fi
done

# --- 2. 核心显示函数 ---
# 把它写成一个独立的函数，方便脚本结尾直接调用，也方便 nb 命令调用
nb_display() {
    CONF_PATH="/etc/s-box/sb.json"
    if [ ! -f "$CONF_PATH" ]; then
        echo "错误: 找不到配置文件 $CONF_PATH"
        return
    fi

    # 提取参数
    IP=$(curl -s -4 icanhazip.com)
    UUID=$(jq -r '.inbounds[0].users[0].uuid' $CONF_PATH)
    PORT=$(jq -r '.inbounds[0].listen_port' $CONF_PATH)
    RAND_DOMAIN=$(jq -r '.inbounds[0].tls.server_name' $CONF_PATH)
    RAND_SHORTID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CONF_PATH)
    PUB_KEY=$(cat /etc/s-box/public.key 2>/dev/null || echo "需手动确认")

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RAND_DOMAIN}&fp=safari&pbk=${PUB_KEY}&sid=${RAND_SHORTID}&type=tcp&headerType=none#TK-Reality-iPhone"

    clear
    echo "==============================================="
    echo "🌟 TikTok 最牛逼的推流环境 - 当前配置信息"
    echo "==============================================="
    echo "🚀 VLESS 订阅二维码 (扫码即用):"
    echo "$VLESS_LINK" | qrencode -t UTF8
    echo ""
    echo "🚀 VLESS 节点链接:"
    echo -e "\033[33m${VLESS_LINK}\033[0m"
    echo ""
    echo "📦 Nikki / Clash 配置参数:"
    echo "-----------------------------------------------"
    echo "  server: $IP"
    echo "  port: $PORT"
    echo "  uuid: $UUID"
    echo "  flow: xtls-rprx-vision"
    echo "  servername: $RAND_DOMAIN"
    echo "  public-key: $PUB_KEY"
    echo "  short-id: $RAND_SHORTID"
    echo "  client-fingerprint: safari"
    echo "-----------------------------------------------"
    echo "✅ 快捷命令已同步：下次登录直接输入 nb 即可显示此界面"
    echo "==============================================="
}

# --- 3. 执行加固逻辑 ---
echo "正在执行环境加固并随机化特征..."
CONF_PATH="/etc/s-box/sb.json"

# 随机特征变换
domains=("www.microsoft.com" "www.lovelive-anime.jp" "www.speedtest.net" "www.yahoo.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH

#  WebRTC 拦截
if ! grep -q "stun" $CONF_PATH; then
    sed -i '/"rules": \[/a \        { "protocol": ["stun"], "outbound": "block" },' $CONF_PATH
fi

# 强制 Safari 指纹对齐
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

# 重启服务
systemctl restart sing-box

# --- 4. 写入 nb 快捷命令 ---
# 为了保证下次登录能用，把 nb_display 的逻辑写进一个独立脚本或永久 alias
if [ ! -f /usr/local/bin/nb ]; then
    # 创建一个永久的可执行命令 nb
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_display)
nb_display
EOF
    chmod +x /usr/local/bin/nb
fi

# --- 5. 搭建完立刻显示 ---
nb_display
