#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS + REALITY 修复版 V4.2 (域名纯净版)
# 修复：域名带括号 / Token正则 / multiplex冲突 / 自签证书订阅
# 默认 HTTP 订阅，完美兼容 Mihomo / OpenClash / Nikki
# 适配 sing-box 1.13.13 | Debian / Ubuntu
# ===============================================================

SB_VER="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080
SUB_YAML_ROOT="/etc/s-box/sub"

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2 python3 iptables-persistent

# 时间同步(REALITY强依赖时间)
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# 防火墙持久放行端口
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
ufw disable >/dev/null 2>&1 || true

# --- 1. 内核优化 BBR/FQ/TCP参数 ---
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
    echo "⚠️  当前内核未启用 BBR（内核版本过低），不影响代理可用性"
fi

# --- 2. 架构与目录初始化 ---
mkdir -p /etc/s-box
case "$(uname -m)" in
    x86_64|amd64)   cpu="amd64" ;;
    aarch64|arm64)  cpu="arm64" ;;
    armv7l|armv7)   cpu="armv7" ;;
    *) echo "不支持CPU架构: $(uname -m)"; exit 1 ;;
esac

# --- 3. 停止旧服务、清理冲突组件 ---
RAND_PORT=443
systemctl stop sing-box sb-sub nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
rm -rf /etc/nginx/sites-available/sub-https /etc/nginx/sites-enabled/sub-https
systemctl daemon-reload
sleep 1

if ss -tlnp 2>/dev/null | grep -q ":$RAND_PORT "; then
    echo "❌ 443端口被Nginx/Caddy等占用，请停止占用程序后重试"
    exit 1
fi

# --- 4. 节点名称 + 36位订阅Token持久化 ---
echo "==============================================="
echo "TikTok矩阵 VLESS-REALITY 一键脚本 V4.2 (域名纯净版)"
echo "==============================================="

OLD_NAME=$(cat /etc/s-box/node_name 2>/dev/null || echo "")
if [ -n "$OLD_NAME" ]; then
    read -r -p "节点名称(旧值:$OLD_NAME，回车保留): " INPUT_NAME
    NODE_NAME="${INPUT_NAME:-$OLD_NAME}"
else
    read -r -p "输入自定义节点名称: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="TK-matrix"
fi
echo "$NODE_NAME" > /etc/s-box/node_name

# 生成36位Hex Token: rand12(24) + sha256截取12 = 合计36位
if [ -f /etc/s-box/sub_token ]; then
    SUB_TOKEN=$(cat /etc/s-box/sub_token)
    echo "✅ 复用已有36位订阅Token: ${SUB_TOKEN:0:8}********"
else
    T1=$(openssl rand -hex 12)
    T2=$(echo "$NODE_NAME$(date +%s)" | openssl dgst -sha256 | awk '{print substr($2,1,12)}')
    SUB_TOKEN="${T1}${T2}"
    echo "$SUB_TOKEN" > /etc/s-box/sub_token
    echo "✅ 生成全新36位订阅Token: ${SUB_TOKEN:0:8}********"
fi
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# --- 5. 安装模式选择 ---
echo "-----------------------------------------------"
echo "1. 全新安装(自动生成REALITY全套参数)"
echo "2. 迁移旧节点(手动填入UUID/密钥/域名)"
read -r -p "请输入数字选择 [1/2]: " MODE

# --- 6. sing-box 二进制安装/更新 ---
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "正在下载 sing-box v$SB_VER ..."
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
else
    echo "✅ sing-box v$SB_VER 已安装，跳过下载"
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box二进制损坏"; exit 1; }

# --- 7. 纯裸域名池（无任何 markdown / 括号符号） ---
domains=(
  "www.intel.com"
  "www.nvidia.com"
  "www.amd.com"
  "www.hp.com"
  "www.samsung.com"
  "www.philips.com"
  "www.bmw.com"
  "www.toyota.com"
  "www.ikea.com"
  "www.sony.com"
  "www.logitech.com"
  "www.motorola.com"
  "www.lenovo.com"
  "www.dell.com"
)

if [ "$MODE" = "2" ]; then
    read -r -p "UUID: " uuid
    read -r -p "公钥Public-Key: " public_key
    read -r -p "私钥Private-Key: " private_key
    read -r -p "Short-ID: " short_id
    read -r -p "伪装SNI域名: " RAND_DOMAIN
else
    IDX=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ' | awk -v n="${#domains[@]}" '{print $1 % n}')
    RAND_DOMAIN=${domains[$IDX]}
    echo "$IDX" > /etc/s-box/domain_idx
    uuid=$(/etc/s-box/sing-box generate uuid)
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    /etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
    private_key=$(grep -i private /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public_key=$(grep -i public /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
    rm -f /tmp/sb_keys.txt
fi
echo "$public_key" > /etc/s-box/public.key

# --- 8. sing-box配置（无 multiplex，避免 vision flow 冲突） ---
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
    echo "❌ sing-box配置校验失败，终止安装"; exit 1
fi

# --- 9. sing-box systemd服务 ---
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box VLESS Reality Service
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

# --- 10. Python HTTP 订阅服务（WorkingDirectory，兼容老版本 Python） ---
cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription plain HTTP server
After=network.target

[Service]
WorkingDirectory=/etc/s-box/sub
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sb-sub
systemctl restart sb-sub

# --- 11. 生成订阅文件函数 gen_sub（HTTP链接） ---
gen_sub() {
    local CP="$CONF_PATH"
    local IP
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null \
      || hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && { echo "⚠️ 无法获取公网IP，请手动填写节点IP"; return 1; }

    local u p sn sid pb name_val token
    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    name_val=$(cat /etc/s-box/node_name)
    token=$(cat /etc/s-box/sub_token)

    cat > "${SUB_YAML_ROOT}/${token}/proxy.yaml" <<YAML
proxies:
  - name: "$name_val-$IP"
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
    echo "✅ 订阅文件更新完成 $name_val-$IP"
}
gen_sub

# --- 12. nb 快捷查询命令（输出HTTP订阅链接） ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null \
      || hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && IP="<手动填入服务器公网IP>"

    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    sn=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CP")
    pb=$(cat /etc/s-box/public.key)
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sn&fp=safari&pbk=$pb&sid=$sid&type=tcp&headerType=none#$node_name-$IP"
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mod_status=$(lsmod | grep -q bbr && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m")
    up_time=$(uptime -p | sed 's/up //')
    boot_time=$(who -b | awk '{print $3,$4}')

    snmp_file="/proc/net/snmp"
    out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' "$snmp_file" | head -n1)
    retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' "$snmp_file" | head -n1)
    snmp_data=$(grep "Tcp:" "$snmp_file" | tail -n1)
    out_segs=$(echo "$snmp_data" | awk "{print \$$out_idx}")
    retr_segs=$(echo "$snmp_data" | awk "{print \$$retr_idx}")
    rate=$(awk "BEGIN {if($out_segs==0) print \"0.0000\"; else printf \"%.4f\", ($retr_segs/$out_segs)*100}")
    rate_int=$(awk "BEGIN {if($out_segs==0) print 0; else printf \"%d\", ($retr_segs/$out_segs)*1000000}")
    if   [ "$rate_int" -lt 5000  ]; then level="\033[42;37m ★ 极佳 (健康) \033[0m"
    elif [ "$rate_int" -lt 15000 ]; then level="\033[44;37m ★ 良好 (亚健康) \033[0m"
    elif [ "$rate_int" -lt 30000 ]; then level="\033[43;30m ⚡ 警告 (线路波动) \033[0m"
    else                                  level="\033[41;37m ❌ 危险 (限流风险) \033[0m"
    fi

    echo "==============================================="
    echo "🖥 系统BBR与线路状态"
    echo "==============================================="
    printf "运行时间: \033[36m%s\033[0m\n" "$up_time"
    printf "系统启动: \033[36m%s\033[0m\n" "$boot_time"
    printf "拥塞算法: \033[32m%s\033[0m\n" "$cc"
    printf "队列算法: \033[32m%s\033[0m\n" "$qdisc"
    printf "BBR内核模块: %b\n" "$mod_status"
    printf "TCP重传率: \033[33m%s%%\033[0m %b\n" "$rate" "$level"
    echo "==============================================="
    printf "节点名称: \033[36m%s-$IP\033[0m\n" "$node_name"
    echo "📋 Clash完整节点配置"
    echo "==============================================="
    printf "  - name: \"%s-$IP\"\n" "$node_name"
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
    echo "🔗 VLESS分享链接（可扫码导入）"
    echo -e "\033[32m$link\033[0m"
    echo "-----------------------------------------------"
    qrencode -t ansiutf8 "$link"
    echo "==============================================="
    echo "📡 HTTP订阅链接（Mihomo/OpenClash/Nikki全兼容）"
    echo "==============================================="
    echo -e "\033[33m$SUB_LINK\033[0m"
    echo "==============================================="
    echo "路由器OpenClash配置片段"
    echo "==============================================="
    cat <<CLASH
proxy-providers:
  ${node_name}-provider:
    type: http
    url: "$SUB_LINK"
    interval: 3600
    proxy: DIRECT
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: $node_name
    type: select
    use:
      - ${node_name}-provider
CLASH

    cat > /etc/s-box/clash-snippet.txt <<SNIPPET
proxy-providers:
  ${node_name}-provider:
    type: http
    url: "$SUB_LINK"
    interval: 3600
    proxy: DIRECT
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
# 注册nb命令
rm -f /usr/local/bin/nb
cat <<'NBINIT' > /usr/local/bin/nb
#!/bin/bash
NBINIT
declare -f nb_info >> /usr/local/bin/nb
echo "nb_info" >> /usr/local/bin/nb
chmod +x /usr/local/bin/nb

# --- 13. rotate-domain 域名轮换工具（纯裸域名，同步更新订阅） ---
cat > /usr/local/bin/rotate-domain <<'ROT'
#!/bin/bash
CONF="/etc/s-box/sb.json"
IDX_FILE="/etc/s-box/domain_idx"
domains=(
  "www.intel.com"
  "www.nvidia.com"
  "www.amd.com"
  "www.hp.com"
  "www.samsung.com"
  "www.philips.com"
  "www.bmw.com"
  "www.toyota.com"
  "www.ikea.com"
  "www.sony.com"
  "www.logitech.com"
  "www.motorola.com"
  "www.lenovo.com"
  "www.dell.com"
)
cur=$(cat "$IDX_FILE" 2>/dev/null || echo 0)
next=$(( (cur + 1) % ${#domains[@]} ))
NEW_DOM=${domains[$next]}
cp "$CONF" "${CONF}.bak"
jq --arg d "$NEW_DOM" '
  .inbounds[0].tls.server_name=$d |
  .inbounds[0].tls.reality.handshake.server=$d
' "$CONF" > /tmp/sb.tmp && mv /tmp/sb.tmp "$CONF"
if /etc/s-box/sing-box check -c "$CONF" >/dev/null 2>&1; then
    systemctl restart sing-box
    echo "$next" > "$IDX_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 切换SNI域名:$NEW_DOM" >> /var/log/domain-rotate.log
    echo "✅ 切换完成：$NEW_DOM"
    TOKEN=$(cat /etc/s-box/sub_token)
    NODE=$(cat /etc/s-box/node_name)
    PB=$(cat /etc/s-box/public.key)
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null)
    IP=$(echo "$IP" | tr -d '[:space:]')
    UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json)
    PORT=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json)
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json)
    if [ -n "$TOKEN" ] && [ -n "$IP" ]; then
        cat > "/etc/s-box/sub/$TOKEN/proxy.yaml" <<YAML
proxies:
  - name: "$NODE-$IP"
    type: vless
    server: $IP
    port: $PORT
    uuid: $UUID
    network: tcp
    udp: false
    tls: true
    flow: xtls-rprx-vision
    servername: $NEW_DOM
    reality-opts:
      public-key: $PB
      short-id: $SID
    client-fingerprint: safari
YAML
        echo "✅ 订阅文件同步更新完毕"
    fi
else
    mv "${CONF}.bak" "$CONF"
    echo "❌ 配置校验失败，自动回滚原域名"
fi
ROT
chmod +x /usr/local/bin/rotate-domain

# 安装完成提示
echo -e "\n===================== 安装完成 ====================="
echo "1. 查看节点信息/订阅链接/二维码：执行  nb"
echo "2. 轮换REALITY伪装SNI域名：       rotate-domain"
echo "3. 查看代理实时日志：             journalctl -u sing-box -f"
echo "===================================================="
/usr/local/bin/nb
