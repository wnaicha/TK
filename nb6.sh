#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS + REALITY 一体版 V4.4
# = V4.3(固定Token) + 域名测速工具(test-domain / 智能rotate-domain)
# 一条命令搞定：装节点 + 固定Token + 测速选域名
# 适配 sing-box 1.13.13 | Debian / Ubuntu
# ===============================================================

SB_VER="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080
SUB_YAML_ROOT="/etc/s-box/sub"

# ⚠️⚠️ 固定盐(私钥)：token 的安全全靠它，务必改成你自己的一串随机字符，
#       并且【每次重装都用同一份脚本(盐不变)】，否则算出的 token 会变。
#       同一套矩阵所有服务器用同一个盐即可；不要外泄。
SUB_SALT="CHANGE-ME-1213"

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2 python3 iptables-persistent

systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

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

# --- 4. 节点名称 + 固定Token(名称+IP+盐 派生) ---
echo "==============================================="
echo "TikTok矩阵 VLESS-REALITY 一键脚本 V4.4 (一体版)"
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

IP_FOR_TOKEN=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || curl -s4m5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP_FOR_TOKEN=$(echo "$IP_FOR_TOKEN" | tr -d '[:space:]')
[ -z "$IP_FOR_TOKEN" ] && { echo "❌ 取不到公网IP，无法生成固定Token"; exit 1; }

SUB_TOKEN=$(echo -n "${NODE_NAME}-${IP_FOR_TOKEN}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
echo "$SUB_TOKEN" > /etc/s-box/sub_token
echo "✅ 固定Token(名称+IP+盐派生): ${SUB_TOKEN:0:8}********  (重装/名称IP不变则恒定)"
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

# --- 7. 纯裸域名池 ---
domains=(
  "www.intel.com"
  "www.hp.com"
  "www.dell.com"
  "www.lenovo.com"
  "www.nvidia.com"
  "www.logitech.com"
  "www.philips.com"
  "www.samsung.com"
  "www.sony.com"
  "www.motorola.com"
  "www.bmw.com"
  "www.toyota.com"
  "www.ikea.com"
  "www.amd.com"
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

# --- 8. sing-box配置（无 multiplex） ---
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

# --- 10. Python HTTP 订阅服务 ---
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

# --- 11. 生成订阅文件 gen_sub ---
gen_sub() {
    local CP="$CONF_PATH"
    local IP
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || curl -s4m5 https://ifconfig.me 2>/dev/null \
      || hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]')
    [ -z "$IP" ] && { echo "⚠️ 无法获取公网IP"; return 1; }

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

# --- 12. nb 快捷查询命令 ---
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

    snmp_file="/proc/net/snmp"
    out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' "$snmp_file" | head -n1)
    retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' "$snmp_file" | head -n1)
    snmp_data=$(grep "Tcp:" "$snmp_file" | tail -n1)
    out_segs=$(echo "$snmp_data" | awk "{print \$$out_idx}")
    retr_segs=$(echo "$snmp_data" | awk "{print \$$retr_idx}")
    rate=$(awk "BEGIN {if($out_segs==0) print \"0.0000\"; else printf \"%.4f\", ($retr_segs/$out_segs)*100}")

    echo "==============================================="
    printf "节点名称: \033[36m%s-$IP\033[0m\n" "$node_name"
    printf "拥塞算法: \033[32m%s\033[0m  队列: \033[32m%s\033[0m  BBR模块: %b\n" "$cc" "$qdisc" "$mod_status"
    printf "运行时间: %s   累计重传率: \033[33m%s%%\033[0m\n" "$up_time" "$rate"
    echo "📋 当前伪装域名: $sn"
    echo "==============================================="
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
rm -f /usr/local/bin/nb
cat <<'NBINIT' > /usr/local/bin/nb
#!/bin/bash
NBINIT
declare -f nb_info >> /usr/local/bin/nb
echo "nb_info" >> /usr/local/bin/nb
chmod +x /usr/local/bin/nb

# --- 13a. test-domain：测全部域名 → 数字手动选 → 应用+同步 ---
cat > /usr/local/bin/test-domain <<'TDEOF'
#!/bin/bash
CONF="/etc/s-box/sb.json"
SB="/etc/s-box/sing-box"
G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; N='\033[0m'
domains=(
  "www.intel.com" "www.hp.com" "www.dell.com" "www.lenovo.com"
  "www.nvidia.com" "www.logitech.com" "www.philips.com" "www.samsung.com"
  "www.sony.com" "www.motorola.com" "www.bmw.com" "www.toyota.com"
  "www.ikea.com" "www.amd.com"
)
test_one(){
  local d="$1" best="" t k
  for k in 1 2; do
    t=$(curl -o /dev/null -s -m 5 -w "%{time_appconnect}" "https://$d" 2>/dev/null)
    { [ -z "$t" ] || [ "$t" = "0.000000" ]; } && continue
    if [ -z "$best" ] || awk "BEGIN{exit !($t<$best)}"; then best="$t"; fi
  done
  echo "$best"
}
echo "==============================================="
echo "  测试 ${#domains[@]} 个伪装域名握手延迟 (<0.1优/0.1-0.3中/>0.3差)"
echo "==============================================="
for i in "${!domains[@]}"; do
  d="${domains[$i]}"; t=$(test_one "$d")
  if [ -z "$t" ]; then
    printf " ${R}%2d)${N} %-18s ${R}超时/失败${N}\n" "$((i+1))" "$d"
  else
    c="$Y"; awk "BEGIN{exit !($t<0.1)}" && c="$G"; awk "BEGIN{exit !($t>0.3)}" && c="$R"
    printf " ${C}%2d)${N} %-18s ${c}%ss${N}\n" "$((i+1))" "$d" "$t"
  fi
done
echo "-----------------------------------------------"
read -r -p "输入数字选择域名 [1-${#domains[@]}]: " n
case "$n" in *[!0-9]*|"") echo "❌ 请输入数字"; exit 1;; esac
if [ "$n" -lt 1 ] || [ "$n" -gt "${#domains[@]}" ]; then echo "❌ 超出范围"; exit 1; fi
SEL="${domains[$((n-1))]}"; echo "→ 选择: $SEL，应用中..."
cp "$CONF" "${CONF}.bak"
jq --arg d "$SEL" '.inbounds[0].tls.server_name=$d | .inbounds[0].tls.reality.handshake.server=$d' "$CONF" > /tmp/sb.tmp && mv /tmp/sb.tmp "$CONF"
if $SB check -c "$CONF" >/dev/null 2>&1; then
  systemctl restart sing-box
  echo "$((n-1))" > /etc/s-box/domain_idx
  TOKEN=$(cat /etc/s-box/sub_token); NODE=$(cat /etc/s-box/node_name); PB=$(cat /etc/s-box/public.key)
  IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null); IP=$(echo "$IP" | tr -d '[:space:]')
  UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF"); PORT=$(jq -r '.inbounds[0].listen_port' "$CONF"); SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF")
  [ -n "$TOKEN" ] && [ -n "$IP" ] && cat > "/etc/s-box/sub/$TOKEN/proxy.yaml" <<YAML
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
    servername: $SEL
    reality-opts:
      public-key: $PB
      short-id: $SID
    client-fingerprint: safari
YAML
  echo "✅ 已切换到 $SEL，sing-box已重启，订阅已同步。客户端刷新即可。"
else
  mv "${CONF}.bak" "$CONF"; echo "❌ 配置校验失败，已回滚"
fi
TDEOF
chmod +x /usr/local/bin/test-domain

# --- 13b. rotate-domain：测速后自动切到最快域名 ---
cat > /usr/local/bin/rotate-domain <<'RDEOF'
#!/bin/bash
CONF="/etc/s-box/sb.json"
SB="/etc/s-box/sing-box"
domains=(
  "www.intel.com" "www.hp.com" "www.dell.com" "www.lenovo.com"
  "www.nvidia.com" "www.logitech.com" "www.philips.com" "www.samsung.com"
  "www.sony.com" "www.motorola.com" "www.bmw.com" "www.toyota.com"
  "www.ikea.com" "www.amd.com"
)
test_one(){
  local d="$1" best="" t k
  for k in 1 2; do
    t=$(curl -o /dev/null -s -m 5 -w "%{time_appconnect}" "https://$d" 2>/dev/null)
    { [ -z "$t" ] || [ "$t" = "0.000000" ]; } && continue
    if [ -z "$best" ] || awk "BEGIN{exit !($t<$best)}"; then best="$t"; fi
  done
  echo "$best"
}
echo "测速选优中（约十几秒）..."
best_i=-1; best_t=""
for i in "${!domains[@]}"; do
  t=$(test_one "${domains[$i]}"); [ -z "$t" ] && continue
  if [ -z "$best_t" ] || awk "BEGIN{exit !($t<$best_t)}"; then best_t="$t"; best_i="$i"; fi
done
if [ "$best_i" -lt 0 ]; then echo "❌ 所有域名都测不通，未切换"; exit 1; fi
SEL="${domains[$best_i]}"; echo "✅ 最优域名: $SEL  (握手 ${best_t}s)"
cp "$CONF" "${CONF}.bak"
jq --arg d "$SEL" '.inbounds[0].tls.server_name=$d | .inbounds[0].tls.reality.handshake.server=$d' "$CONF" > /tmp/sb.tmp && mv /tmp/sb.tmp "$CONF"
if $SB check -c "$CONF" >/dev/null 2>&1; then
  systemctl restart sing-box
  echo "$best_i" > /etc/s-box/domain_idx
  echo "$(date '+%Y-%m-%d %H:%M:%S') 自动切到最快域名:$SEL (${best_t}s)" >> /var/log/domain-rotate.log
  TOKEN=$(cat /etc/s-box/sub_token); NODE=$(cat /etc/s-box/node_name); PB=$(cat /etc/s-box/public.key)
  IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null); IP=$(echo "$IP" | tr -d '[:space:]')
  UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF"); PORT=$(jq -r '.inbounds[0].listen_port' "$CONF"); SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF")
  [ -n "$TOKEN" ] && [ -n "$IP" ] && cat > "/etc/s-box/sub/$TOKEN/proxy.yaml" <<YAML
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
    servername: $SEL
    reality-opts:
      public-key: $PB
      short-id: $SID
    client-fingerprint: safari
YAML
  echo "✅ 已切换并同步订阅。客户端刷新即可。"
else
  mv "${CONF}.bak" "$CONF"; echo "❌ 配置校验失败，已回滚"
fi
RDEOF
chmod +x /usr/local/bin/rotate-domain

# 安装完成提示
echo -e "\n===================== 安装完成 ====================="
echo "1. 查看节点信息/订阅/二维码： nb"
echo "2. 测全部域名延迟、手动选最优： test-domain"
echo "3. 自动切到握手最快的域名：     rotate-domain"
echo "4. 查看实时日志：               journalctl -u sing-box -f"
echo "===================================================="
/usr/local/bin/nb
