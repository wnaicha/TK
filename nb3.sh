#!/bin/bash
set -e

# ===============================================================
#  TikTok 矩阵环境 - VLESS + REALITY + 订阅自动同步版 (V3.0)
#  新增：节点自定义命名 / 复杂固定Token / 订阅链接自动生成
#  适配 sing-box 1.13.x | 仅支持 Debian / Ubuntu
# ===============================================================

SB_VER="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2 python3

# 时间同步
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# 防火墙
ufw disable >/dev/null 2>&1 || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT -j ACCEPT 2>/dev/null || true

# --- 1. 内核优化 (BBR / FQ / FastOpen / TCP缓冲) ---
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d;/^net\.ipv4\.tcp_fastopen/d;/^net\.ipv4\.tcp_window_scaling/d;/^net\.ipv4\.tcp_mtu_probing/d;/^net\.ipv6\.conf\.all\.disable_ipv6/d;/^net\.ipv6\.conf\.default\.disable_ipv6/d;/^net\.ipv4\.tcp_rmem/d;/^net\.ipv4\.tcp_wmem/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
CONF

modprobe tcp_bbr 2>/dev/null || true
sysctl -p >/dev/null 2>&1 || true
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "⚠️  当前内核未启用 BBR（可能内核过旧），不影响代理可用性，仅影响速度优化"
fi

# --- 2. 路径与架构检测 ---
mkdir -p /etc/s-box
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

# --- 4. 节点名称 & Token 设置 ---
echo "==============================================="
echo "  TikTok 矩阵环境 - REALITY 安装 (sing-box v$SB_VER)"
echo "==============================================="

# 节点名称：每次都询问，支持自定义
OLD_NAME=$(cat /etc/s-box/node_name 2>/dev/null || echo "")
if [ -n "$OLD_NAME" ]; then
    read -r -p "节点名称 (上次: $OLD_NAME，直接回车保留，或输入新名称): " INPUT_NAME
    NODE_NAME="${INPUT_NAME:-$OLD_NAME}"
else
    read -r -p "输入节点名称 (如 xmg150): " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="TK-node"
fi
echo "$NODE_NAME" > /etc/s-box/node_name

# Token：首次自动生成复杂Token并保存，重装自动复用
if [ -f /etc/s-box/sub_token ]; then
    SUB_TOKEN=$(cat /etc/s-box/sub_token)
    echo "✅ 复用已有订阅Token: ${SUB_TOKEN:0:8}********"
else
    # 生成48位复杂Token：时间戳+随机hex+节点名hash混合
    T1=$(openssl rand -hex 12)
    T2=$(echo "$NODE_NAME$(date +%s)" | openssl dgst -sha256 | awk '{print substr($2,1,12)}')
    SUB_TOKEN="${T1}${T2}"
    echo "$SUB_TOKEN" > /etc/s-box/sub_token
    echo "✅ 已生成新订阅Token: ${SUB_TOKEN:0:8}********"
fi

mkdir -p "/etc/s-box/sub/$SUB_TOKEN"

# --- 5. 安装模式选择 ---
echo "-----------------------------------------------"
echo " 1. 全新安装 (随机域名 + 随机参数)"
echo " 2. 参数还原 (手动输入旧参数)"
read -r -p "请选择 [1-2]: " MODE

# --- 6. 下载 sing-box 并校验 ---
if [ ! -x "/etc/s-box/sing-box" ]; then
    wget -O /etc/s-box/sing-box.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box 安装失败"; exit 1; }

# --- 7. 生成 / 还原参数 ---
domains=(
  "www.intel.com"
  "www.nvidia.com"
  "www.amd.com"
  "www.hp.com"
  "www.cisco.com"
  "www.philips.com"
  "www.bosch.com"
  "www.bmw.com"
  "www.toyota.com"
  "www.ikea.com"
  "www.sony.com"
  "www.lovelive-anime.jp"
  "www.sap.com"
  "www.oracle.com"
  "www.adobe.com"
  "www.visa.com"
  "www.mastercard.com"
  "www.paypal.com"
)

if [ "$MODE" = "2" ]; then
    read -r -p "输入 UUID: "        uuid
    read -r -p "输入 Public-Key: "  public_key
    read -r -p "输入 Private-Key: " private_key
    read -r -p "输入 Short-ID: "    short_id
    read -r -p "输入伪装域名: "      RAND_DOMAIN
else
    IDX=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ' | awk -v n="${#domains[@]}" '{print $1 % n}')
    RAND_DOMAIN=${domains[$IDX]}
    echo "$IDX" > /etc/s-box/domain_idx
    uuid=$(/etc/s-box/sing-box generate uuid)
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public_key=$(grep -i "public"  /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    rm -f /tmp/sb_keys.txt
fi

echo "$public_key" > /etc/s-box/public.key

# --- 8. 写入服务端配置 ---
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

if ! /etc/s-box/sing-box check -c "$CONF_PATH"; then
    echo "❌ 配置校验失败，已中止"; exit 1
fi

# --- 9. systemd 服务 ---
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

# --- 10. 生成订阅文件函数 ---
gen_sub() {
    local CP="$CONF_PATH"
    local IP
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && { echo "❌ 无法获取公网IP，订阅文件未生成"; return 1; }

    local u p sn sid pb name_val token
    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    name_val=$(cat /etc/s-box/node_name 2>/dev/null || echo "TK-node")
    token=$(cat /etc/s-box/sub_token)

    cat > "/etc/s-box/sub/$token/proxy.yaml" <<YAML
proxies:
  - name: "$name_val"
    type: vless
    server: $IP
    port: $p
    uuid: $u
    network: tcp
    udp: false
    tls: true
    flow: xtls-rprx-vision
    servername: $sn
    reality-opts:
      public-key: $pb
      short-id: $sid
    client-fingerprint: safari
YAML
    echo "✅ 订阅文件已更新 → $name_val @ $IP"
}

gen_sub

# --- 11. 订阅HTTP服务 (Python3) ---
cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription HTTP server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT --directory /etc/s-box/sub
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sb-sub
systemctl restart sb-sub

# --- 12. nb 快捷命令 ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"

    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && IP="<请手动填入服务器IP>"

    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    node_name=$(cat /etc/s-box/node_name 2>/dev/null || echo "TK-node")
    sub_token=$(cat /etc/s-box/sub_token 2>/dev/null || echo "")
    link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#$node_name"

    # BBR / 系统状态
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mod_status=$(lsmod | grep -q "bbr" && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m")
    up_time=$(uptime -p | sed 's/up //')
    boot_time=$(who -b | awk '{print $3,$4}')

    # 重传率（防除零）
    snmp_file="/proc/net/snmp"
    out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' "$snmp_file" | head -n 1)
    retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' "$snmp_file" | head -n 1)
    snmp_data=$(grep "Tcp:" "$snmp_file" | tail -n 1)
    out_segs=$(echo "$snmp_data" | awk "{print \$$out_idx}")
    retr_segs=$(echo "$snmp_data" | awk "{print \$$retr_idx}")
    rate=$(awk "BEGIN {if ($out_segs==0) print \"0.0000\"; else printf \"%.4f\", ($retr_segs/$out_segs)*100}")
    rate_int=$(awk "BEGIN {if ($out_segs==0) print \"0\"; else printf \"%d\", ($retr_segs/$out_segs)*1000000}")
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
    printf "📛 节 点 名   : \033[36m%s\033[0m\n" "$node_name"
    echo "📋 Nikki / Clash 完整参数"
    echo "==============================================="
    printf "  - name: \"%s\"\n" "$node_name"
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
    echo "-----------------------------------------------"
    echo "🔗 VLESS 链接 / 📱 二维码"
    echo -e "\033[32m$link\033[0m"
    echo "-----------------------------------------------"
    qrencode -t ansiutf8 "$link"
    echo "==============================================="
    echo "📡 订阅链接 (Nikki / OpenClash proxy-providers)"
    echo "==============================================="
    echo -e "\033[33mhttp://$IP:8080/$sub_token/proxy.yaml\033[0m"
    echo "==============================================="
    echo "📋 路由器配置片段 (直接复制到 Nikki/OpenClash)"
    echo "==============================================="
    cat <<CLASH
# ---- proxy-providers ----
proxy-providers:
  ${node_name}-provider:
    type: http
    url: "http://$IP:8080/$sub_token/proxy.yaml"
    interval: 3600
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300

# ---- proxy-groups ----
proxy-groups:
  - name: $node_name
    type: select
    use:
      - ${node_name}-provider

# ---- rules (按需填入设备IP) ----
# - SRC-IP-CIDR,192.168.x.x/32,$node_name
CLASH
    echo "==============================================="

    # 同时保存到文件，方便以后查阅
    cat > /etc/s-box/clash-snippet.txt <<SNIPPET
proxy-providers:
  ${node_name}-provider:
    type: http
    url: "http://$IP:8080/$sub_token/proxy.yaml"
    interval: 3600
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: $node_name
    type: select
    use:
      - ${node_name}-provider
SNIPPET
}

rm -f /usr/local/bin/nb
cat <<'NBEOF' > /usr/local/bin/nb
#!/bin/bash
NBEOF
declare -f nb_info >> /usr/local/bin/nb
echo "nb_info" >> /usr/local/bin/nb
chmod +x /usr/local/bin/nb

# --- 13. 域名轮询脚本 (rotate-domain，切换后同步更新订阅文件) ---
cat > /usr/local/bin/rotate-domain <<'ROTEOF'
#!/bin/bash
CONF="/etc/s-box/sb.json"
IDX_FILE="/etc/s-box/domain_idx"

domains=(
  "www.intel.com"
  "www.nvidia.com"
  "www.amd.com"
  "www.hp.com"
  "www.cisco.com"
  "www.philips.com"
  "www.bosch.com"
  "www.bmw.com"
  "www.toyota.com"
  "www.ikea.com"
  "www.sony.com"
  "www.lovelive-anime.jp"
  "www.sap.com"
  "www.oracle.com"
  "www.adobe.com"
  "www.visa.com"
  "www.mastercard.com"
  "www.paypal.com"
)

cur=$(cat "$IDX_FILE" 2>/dev/null || echo "0")
next=$(( (cur + 1) % ${#domains[@]} ))
NEW_DOMAIN=${domains[$next]}

cp "$CONF" "${CONF}.bak"

jq --arg d "$NEW_DOMAIN" '
  .inbounds[0].tls.server_name = $d |
  .inbounds[0].tls.reality.handshake.server = $d
' "$CONF" > /tmp/sb_new.json && mv /tmp/sb_new.json "$CONF"

if /etc/s-box/sing-box check -c "$CONF" >/dev/null 2>&1; then
    systemctl restart sing-box
    echo "$next" > "$IDX_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 域名已切换 → $NEW_DOMAIN" >> /var/log/domain-rotate.log
    echo "✅ 已切换到: $NEW_DOMAIN"

    # 同步更新订阅文件，客户端下次拉取自动获得新域名
    TOKEN=$(cat /etc/s-box/sub_token 2>/dev/null || echo "")
    NODE=$(cat /etc/s-box/node_name 2>/dev/null || echo "TK-node")
    PB=$(cat /etc/s-box/public.key)
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF")
    PORT=$(jq -r '.inbounds[0].listen_port' "$CONF")
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF")

    if [ -n "$TOKEN" ] && [ -n "$IP" ]; then
        cat > "/etc/s-box/sub/$TOKEN/proxy.yaml" <<YAML
proxies:
  - name: "$NODE"
    type: vless
    server: $IP
    port: $PORT
    uuid: $UUID
    udp: false
    tls: true
    flow: xtls-rprx-vision
    servername: $NEW_DOMAIN
    reality-opts:
      public-key: $PB
      short-id: $SID
    client-fingerprint: safari
YAML
        echo "✅ 订阅文件已同步更新"
    fi
else
    mv "${CONF}.bak" "$CONF"
    echo "❌ 配置校验失败，已自动回滚，域名未切换"
fi
ROTEOF
chmod +x /usr/local/bin/rotate-domain

echo "✅ 手动切换域名：执行 rotate-domain，订阅自动同步"

# 安装完毕输出
sleep 1
if ! systemctl is-active --quiet sing-box; then
    echo "⚠️  sing-box 未正常启动，请执行: journalctl -u sing-box -n 30"
fi
/usr/local/bin/nb
