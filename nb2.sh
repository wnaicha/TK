#!/bin/bash
set -e
 
# ===============================================================
#  TikTok 矩阵环境 - VLESS + REALITY - WebRTC/UDP 物理拦截版
#  适配 sing-box 1.13.x 新配置语法（旧 sniff/block 写法已失效）
#  仅支持 Debian / Ubuntu
# ===============================================================
 
SB_VER="1.13.13"
 
# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }
 
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2
 
# 时间同步
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true
 
# 防火墙
ufw disable >/dev/null 2>&1 || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
 
# --- 1. 内核优化 (BBR / FQ / FastOpen) ---
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
 
# 精确匹配行首，避免误删注释或其它配置
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
echo " 1. 全新安装 (随机域名 + 随机参数)"
echo " 2. 参数还原 (手动输入旧参数)"
read -r -p "请选择 [1-2]: " MODE
 
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
 
# --- 5. 生成 / 还原参数 ---
domains=(
  "addons.mozilla.org"       # Mozilla CDN，TLS 1.3，全球可达
  "www.tesla.com"            # 大厂低频，TLS 配置干净
  "fivem.net"                # 游戏平台，社区长期验证
  "www.lovelive-anime.jp"    # 经典 REALITY 推荐，长期稳定
  "dl.google.com"            # Google 下载节点，全球可达
  "www.intel.com"    # Google API，TLS 1.3
  "www.nvidia.com"           # 英伟达，TLS 配置好
  "www.adobe.com"            # Adobe CDN，全球节点
  "www.dropbox.com"          # Dropbox，TLS 1.3
  "www.twitch.tv"            # 流媒体平台，大流量掩护好
  "www.linkedin.com"         # 微软旗下，TLS 配置稳定
  "www.hp.com"  # GitHub 静态资源，全球 CDN
  "www.paypal.com"           # 金融类，TLS 配置严格规范
  "www.cisco.com"         # 开源 CDN，全球节点多
)
 
if [ "$MODE" = "2" ]; then
    read -r -p "输入 UUID: "        uuid
    read -r -p "输入 Public-Key: "  public_key
    read -r -p "输入 Private-Key: " private_key
    read -r -p "输入 Short-ID: "    short_id
    read -r -p "输入伪装域名: "      RAND_DOMAIN
else
    RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}
    uuid=$(/etc/s-box/sing-box generate uuid)
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public_key=$(grep -i "public"  /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    rm -f /tmp/sb_keys.txt
fi
 
echo "$public_key" > /etc/s-box/public.key
 
# --- 6. 写入服务端配置 (1.13 新语法：route action reject) ---
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
 
# 启动前校验配置
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
 
# --- 8. nb 快捷命令（含连接参数 + BBR状态 + 网络质量）---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
 
    # 获取公网 IP（多备用源）
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && IP="<请手动填入服务器IP>"
 
    # 从配置文件读取参数
    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#TK-$IP"
 
    # BBR / 系统状态
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mod_status=$(lsmod | grep -q "bbr" && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m")
    up_time=$(uptime -p | sed 's/up //')
    boot_time=$(who -b | awk '{print $3,$4}')
 
    # 重传率
    snmp_file="/proc/net/snmp"
    out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' "$snmp_file" | head -n 1)
    retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' "$snmp_file" | head -n 1)
    snmp_data=$(grep "Tcp:" "$snmp_file" | tail -n 1)
    out_segs=$(echo "$snmp_data" | awk "{print \$$out_idx}")
    retr_segs=$(echo "$snmp_data" | awk "{print \$$retr_idx}")
    rate=$(awk "BEGIN {printf \"%.4f\", ($retr_segs/$out_segs)*100}")
    rate_int=$(awk "BEGIN {printf \"%d\", ($retr_segs/$out_segs)*1000000}")
    if   [ "$rate_int" -lt 5000  ]; then level="\033[42;37m ★ 极佳 (健康) \033[0m"
    elif [ "$rate_int" -lt 15000 ]; then level="\033[44;37m ★ 良好 (亚健康) \033[0m"
    elif [ "$rate_int" -lt 30000 ]; then level="\033[43;30m ⚡ 警告 (线路波动) \033[0m"
    else                                  level="\033[41;37m ❌ 危险 (极高限流风险) \033[0m"
    fi
 
    echo "==============================================="
    echo "🖥  系统 & BBR 状态"
    echo "==============================================="
    printf "🚀 运行时间   : \033[36m%s\033[0m\n" "$up_time"
    printf "📅 启动时间   : \033[36m%s\033[0m\n" "$boot_time"
    printf "✅ 拥塞算法   : \033[32m%s\033[0m\n" "$cc"
    printf "✅ 队列算法   : \033[32m%s\033[0m\n" "$qdisc"
    printf "✅ BBR 模块   : %b\n"                "$mod_status"
    printf "📉 重 传 率   : \033[33m%s%%\033[0m  " "$rate"
    printf "%b\n" "$level"
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
cat <<'NBEOF' > /usr/local/bin/nb
#!/bin/bash
NBEOF
declare -f nb_info >> /usr/local/bin/nb
echo "nb_info" >> /usr/local/bin/nb
chmod +x /usr/local/bin/nb
 
# 安装完毕输出
sleep 1
if ! systemctl is-active --quiet sing-box; then
    echo "⚠️  sing-box 未正常启动，请执行: journalctl -u sing-box -n 30"
fi
/usr/local/bin/nb
 
