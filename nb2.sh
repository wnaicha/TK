#!/bin/bash
set -e

# ===============================================================
#  TikTok 矩阵环境 - VLESS + REALITY - WebRTC/UDP 物理拦截版
#  适配 sing-box 1.13.x 新配置语法（旧 sniff/block 写法已失效）
#  仅支持 Debian / Ubuntu
# ===============================================================

# 想升级版本时，只改这一行即可（去 GitHub Releases 看最新 stable 版本号）
SB_VER="1.13.13"

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2

# 时间同步：REALITY 对系统时间精度很敏感，必须保证 NTP 在跑
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# 防火墙：关闭 ufw 并显式放行 443（不再全量 flush iptables，避免误伤）
ufw disable >/dev/null 2>&1 || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

# --- 1. 内核优化 (BBR / FQ / FastOpen) ---
# 强制 IPv4-only：保证 TikTok 看到的出口 IP 始终是这台 VPS 的单一 IPv4，避免 v6 串号
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

# 只清理我们自己加过的 net.* 行（精确匹配行首，避免误删注释或其它配置）
sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d;/^net\.ipv4\.tcp_fastopen/d;/^net\.ipv4\.tcp_window_scaling/d;/^net\.ipv4\.tcp_mtu_probing/d;/^net\.ipv6\.conf\.all\.disable_ipv6/d;/^net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
CONF

# 加载并校验 BBR（老内核没编译模块时给出提示，而不是默默失效）
modprobe tcp_bbr 2>/dev/null || true
sysctl -p >/dev/null 2>&1 || true
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "⚠️  当前内核未启用 BBR（可能内核过旧），不影响代理可用性，仅影响速度优化"
fi

# --- 2. 路径与架构检测 ---
mkdir -p /etc/s-box
CONF_PATH="/etc/s-box/sb.json"
case "$(uname -m)" in
    x86_64|amd64)   cpu="amd64" ;;
    aarch64|arm64)  cpu="arm64" ;;
    armv7l|armv7)   cpu="armv7" ;;
    *) echo "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
esac

# --- 3. 端口占用检查 ---
RAND_PORT=443
if ss -tlnp 2>/dev/null | grep -q ":$RAND_PORT "; then
    echo "❌ $RAND_PORT 端口已被占用，请先停掉占用进程（如 nginx/caddy）再重试"
    exit 1
fi

echo "==============================================="
echo "  TikTok 矩阵环境 - REALITY 安装 (sing-box v$SB_VER)"
echo "==============================================="

# --- 4. 下载 sing-box 并校验 ---
if [ ! -x "/etc/s-box/sing-box" ]; then
    wget -O /etc/s-box/sing-box.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box 安装失败"; exit 1; }

# --- 5. 生成随机参数 ---
domains=("www.microsoft.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com" "www.speedtest.net" "www.yahoo.com" "www.amd.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
uuid=$(/etc/s-box/sing-box generate uuid)
short_id=$(/etc/s-box/sing-box generate rand --hex 4)
/etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
public_key=$(grep -i "public"  /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
rm -f /tmp/sb_keys.txt
echo "$public_key" > /etc/s-box/public.key

# --- 6. 写入服务端配置 (1.13 新语法：用 route action reject，不再用 block 出站) ---
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $RAND_PORT,
      "users": [
        { "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$RAND_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$RAND_DOMAIN", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "network": "udp", "action": "reject" }
    ],
    "final": "direct"
  }
}
JSON

# 启动前先校验配置，配置有错就不动现有服务
if ! /etc/s-box/sing-box check -c "$CONF_PATH"; then
    echo "❌ 配置校验失败，已中止"; exit 1
fi

# --- 7. systemd 服务 ---
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target chrony.service

[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# --- 8. 快捷 nb 命令 (输出完整参数 + 链接 + 二维码) ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null || curl -s4m5 https://ifconfig.me 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && IP="<请手动填入服务器IP>"
    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP"

    echo "==============================================="
    echo "📋 Nikki / Clash 完整参数 (UDP 已物理封杀，防 WebRTC 泄露)"
    echo "==============================================="
    printf "  - name: \"TK-%s\"\n" "$IP"
    printf "    type: vless\n"
    printf "    server: %s\n" "$IP"
    printf "    port: %s\n" "$p"
    printf "    uuid: %s\n" "$u"
    printf "    udp: false          # <--- WebRTC 核心封杀点（客户端侧）\n"
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

# 安装完直接输出
sleep 1
if ! systemctl is-active --quiet sing-box; then
    echo "⚠️  sing-box 未正常启动，请执行: journalctl -u sing-box -n 30"
fi
/usr/local/bin/nb
