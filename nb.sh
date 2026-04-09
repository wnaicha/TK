#!/bin/bash

# --- 1. 自动检查并安装必要依赖 ---
for pkg in qrencode jq curl; do
    if ! command -v $pkg >/dev/null 2>&1; then
        echo "正在安装必要组件: $pkg ..."
        if [ -f /etc/debian_version ]; then
            apt update -y && apt install -y $pkg > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y $pkg > /dev/null 2>&1
        fi
    fi
done

# --- 2. 核心显示函数 (nb) ---
nb_info() {
    # 路径自动识别逻辑 (兼容勇哥不同版本)
    if [ -f "/etc/s-box/sb.json" ]; then
        CP="/etc/s-box/sb.json"
    elif [ -f "/etc/v2ray-agent/sing-box/conf/config.json" ]; then
        CP="/etc/v2ray-agent/sing-box/conf/config.json"
    else
        echo "❌ 错误: 找不到配置文件！"
        return
    fi
    
    # 实时提取参数
    IP=$(curl -s -4 icanhazip.com)
    UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // .users[0].id' $CP | head -n 1)
    PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // .port' $CP | head -n 1)
    # 提取当前生效的域名和ShortID
    S_NAME=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name // .tls.reality.handshake.server' $CP | head -n 1)
    S_ID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' $CP | head -n 1)
    
    # 提取公钥
    [ -f "/etc/s-box/public.key" ] && PUB_KEY=$(cat /etc/s-box/public.key) || PUB_KEY="需在脚本目录查看"

    # 拼接 VLESS 链接 (fp写死safari)
    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${S_NAME}&fp=safari&pbk=${PUB_KEY}&sid=${S_ID}&type=tcp&headerType=none#TK-Pure-TCP"

    clear
    echo "==============================================="
    echo "🌟 TikTok 纯 TCP 运营环境 - 当前配置 (nb)"
    echo "==============================================="
    echo "🚀 VLESS 订阅二维码 (扫码即用):"
    echo "$VLESS_LINK" | qrencode -t UTF8
    echo ""
    echo "🚀 VLESS 节点链接:"
    echo -e "\033[33m${VLESS_LINK}\033[0m"
    echo ""
    echo "📦 Nikki / Clash 核心参数 (检查重点！):"
    echo "-----------------------------------------------"
    echo -e "\033[32m  udp: false\033[0m              # <--- 已锁定：彻底封杀 WebRTC 泄露"
    echo -e "\033[32m  tls: true\033[0m               # <--- 已锁定：Reality 必须开启"
    echo "  flow: xtls-rprx-vision"
    echo "  servername: $S_NAME"
    echo "  reality-opts:"
    echo "    public-key: $PUB_KEY"
    echo "    short-id: $S_ID"
    echo -e "\033[32m  client-fingerprint: safari\033[0m # <--- 已锁定：防止误判为 Android"
    echo "-----------------------------------------------"
    echo "✅ 提示：下次登录输入 nb 即可显示此界面"
    echo "==============================================="
}

# --- 3. 写入永久 nb 命令 ---
if [ ! -f /usr/local/bin/nb ]; then
    cat <<EOF > /usr/local/bin/nb
#!/bin/bash
$(declare -f nb_info)
nb_info
EOF
    chmod +x /usr/local/bin/nb
fi

# --- 4. 执行特征随机化与环境加固 ---
# 再次确认识别路径
if [ -f "/etc/s-box/sb.json" ]; then
    CONF_PATH="/etc/s-box/sb.json"
elif [ -f "/etc/v2ray-agent/sing-box/conf/config.json" ]; then
    CONF_PATH="/etc/v2ray-agent/sing-box/conf/config.json"
fi

echo "正在执行环境加固并锁定纯 TCP 模式..."

# 随机特征池
domains=("www.microsoft.com" "www.lovelive-anime.jp" "www.speedtest.net" "www.yahoo.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
RAND_SHORTID=$(openssl rand -hex 4)

# 1. 替换伪装域名和 ShortID
sed -i "s/\"server_name\": \".*\"/\"server_name\": \"$RAND_DOMAIN\"/g" $CONF_PATH
sed -i "s/\"short_id\": \".*\"/\"short_id\": [\"$RAND_SHORTID\"]/g" $CONF_PATH

# 2. 注入勇哥同款拦截：在路由规则里 block 掉 stun (UDP探测协议)
if ! grep -q "stun" $CONF_PATH; then
    sed -i '/"rules": \[/a \        { "protocol": ["stun"], "outbound": "block" },' $CONF_PATH
fi

# 3. 强制指纹对齐 Safari
sed -i 's/"fingerprint": "chrome"/"fingerprint": "safari"/g' $CONF_PATH

# 4. 重启服务
systemctl restart sing-box

# --- 5. 立即显示结果 ---
nb_info
