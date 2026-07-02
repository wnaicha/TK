#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS/Trojan + TLS (自有域名) V7.0
#  - 安装时二选一协议：VLESS+Vision 或 Trojan
#  - Cloudflare API 自动解析域名（Token/ZoneID 仅内存使用，不落盘）
#  - SUB_SALT 运行时输入，不写入脚本/文件，脚本可安全公开
#  - 支持自定义监听端口
#  - 域名/邮箱/UUID或密码/端口/协议/节点名 全部持久化，重装零改动
#  - 保留：禁UDP / BBR / 固定Token / 节点名带IP / HTTP订阅
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
apt-get install -y jq socat curl wget openssl tar chrony qrencode iproute2 python3 iptables-persistent dnsutils

systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# --- 1. 内核优化 BBR/FQ ---
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

# --- 2. 架构与目录 ---
mkdir -p /etc/s-box /etc/s-box/acme
case "$(uname -m)" in
    x86_64|amd64)   cpu="amd64" ;;
    aarch64|arm64)  cpu="arm64" ;;
    armv7l|armv7)   cpu="armv7" ;;
    *) echo "不支持CPU架构: $(uname -m)"; exit 1 ;;
esac

# --- 3. 停旧服务 ---
systemctl stop sing-box sb-sub nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
systemctl daemon-reload
sleep 1

# ================================================================
# 交互配置
# ================================================================
echo "==============================================="
echo "TikTok矩阵 VLESS/Trojan 自有域名版 V7.0"
echo "==============================================="

# ---- SUB_SALT（订阅Token盐，仅内存，不落盘，所有机器填同一个） ----
echo ""
echo "【1/7】订阅Token盐值（所有机器填同一个固定字符串，决定订阅链接路径）"
echo "      脚本不会存储此值，每次重装需重新输入，请自己记好。"
read -r -s -p "SUB_SALT（不回显）: " SUB_SALT
echo ""
[ -z "$SUB_SALT" ] && { echo "❌ SUB_SALT 不能为空"; exit 1; }

# ---- Cloudflare 凭据（仅内存，不落盘） ----
echo ""
echo "【2/7】Cloudflare API 凭据（仅本次使用，脚本结束后不会保留在服务器）"
echo "      获取方式：CF控制台 → 右上角头像 → My Profile → API Tokens"
echo "      创建Token时选模板 [Edit zone DNS]，Zone选你的域名"
read -r -s -p "CF API Token（不回显）: " CF_TOKEN
echo ""
[ -z "$CF_TOKEN" ] && { echo "❌ CF_TOKEN 不能为空"; exit 1; }

echo "      Zone ID：CF控制台 → 点你的域名 → 右侧 Overview 页往下拉"
read -r -p "CF Zone ID: " CF_ZONE_ID
[ -z "$CF_ZONE_ID" ] && { echo "❌ CF_ZONE_ID 不能为空"; exit 1; }

# ---- 协议选择 ----
echo ""
echo "【3/7】协议选择"
OLD_PROTO=$(cat /etc/s-box/protocol 2>/dev/null || echo "")
if [ -n "$OLD_PROTO" ]; then
    read -r -p "选择协议 [1]VLESS+Vision [2]Trojan (旧值:$OLD_PROTO，回车保留): " INPUT_PROTO
else
    read -r -p "选择协议 [1]VLESS+Vision [2]Trojan (回车默认1): " INPUT_PROTO
fi
case "$INPUT_PROTO" in
    1) PROTO="vless" ;;
    2) PROTO="trojan" ;;
    "") PROTO="${OLD_PROTO:-vless}" ;;
    vless|trojan) PROTO="$INPUT_PROTO" ;;
    *) echo "❌ 只能选 1 或 2"; exit 1 ;;
esac
echo "$PROTO" > /etc/s-box/protocol
echo "✅ 协议: $PROTO"

# ---- 节点名称 ----
echo ""
echo "【4/7】节点名称"
OLD_NAME=$(cat /etc/s-box/node_name 2>/dev/null || echo "")
if [ -n "$OLD_NAME" ]; then
    read -r -p "节点名称(旧值:$OLD_NAME，回车保留): " INPUT_NAME
    NODE_NAME="${INPUT_NAME:-$OLD_NAME}"
else
    read -r -p "节点名称(如 US-LA-01，回车默认TK-matrix): " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="TK-matrix"
fi
echo "$NODE_NAME" > /etc/s-box/node_name
echo "✅ 节点名: $NODE_NAME"

# ---- 子域名 ----
echo ""
echo "【5/7】子域名"
echo "      A记录将自动创建/更新，指向本机IP，无需手动操作CF控制台"
OLD_DOMAIN=$(cat /etc/s-box/domain 2>/dev/null || echo "")
if [ -n "$OLD_DOMAIN" ]; then
    read -r -p "子域名(旧值:$OLD_DOMAIN，回车保留): " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-$OLD_DOMAIN}"
else
    read -r -p "子域名 (如 us1.yourdomain.com): " DOMAIN
fi
[ -z "$DOMAIN" ] && { echo "❌ 必须填子域名"; exit 1; }
echo "$DOMAIN" > /etc/s-box/domain

# ---- ACME邮箱 ----
echo ""
echo "【6/7】ACME邮箱（Let's Encrypt 证书通知用）"
OLD_EMAIL=$(cat /etc/s-box/acme_email 2>/dev/null || echo "")
if [ -n "$OLD_EMAIL" ]; then
    ACME_EMAIL="$OLD_EMAIL"
    echo "✅ 复用已有邮箱: $ACME_EMAIL"
else
    read -r -p "ACME邮箱(回车默认 admin@$DOMAIN): " ACME_EMAIL
    [ -z "$ACME_EMAIL" ] && ACME_EMAIL="admin@$DOMAIN"
    echo "$ACME_EMAIL" > /etc/s-box/acme_email
fi

# ---- 监听端口 ----
echo ""
echo "【7/7】代理监听端口（443被封可改成 8443/2053/2083/2087/2096 等）"
OLD_PORT=$(cat /etc/s-box/listen_port 2>/dev/null || echo "")
if [ -n "$OLD_PORT" ]; then
    read -r -p "端口(旧值:$OLD_PORT，回车保留): " INPUT_PORT
    RAND_PORT="${INPUT_PORT:-$OLD_PORT}"
else
    read -r -p "端口(回车默认443): " INPUT_PORT
    RAND_PORT="${INPUT_PORT:-443}"
fi
case "$RAND_PORT" in
    ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1 ;;
esac
if [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; then
    echo "❌ 端口范围 1-65535"; exit 1
fi
if [ "$RAND_PORT" = "80" ] || [ "$RAND_PORT" = "$SUB_PORT" ]; then
    echo "❌ 与ACME(80)或订阅服务($SUB_PORT)端口冲突，请换一个"; exit 1
fi
echo "$RAND_PORT" > /etc/s-box/listen_port
echo "✅ 代理端口: $RAND_PORT"

# ================================================================
# 获取公网IP
# ================================================================
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 取不到公网IP"; exit 1; }
echo ""
echo "📡 本机公网IP: $IP"

# ================================================================
# Cloudflare 自动解析 A 记录（Token/ZoneID 仅在此处使用，不写文件）
# ================================================================
echo ""
echo "🌐 正在通过 Cloudflare API 设置 DNS A 记录..."
echo "   $DOMAIN → $IP（橙云关闭，proxied=false）"

_cf_api() {
    local method="$1" path="$2" data="$3"
    curl -s -X "$method" \
        "https://api.cloudflare.com/client/v4${path}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        ${data:+--data "$data"}
}

# 验证Token有效性
_verify=$(  _cf_api GET "/zones/${CF_ZONE_ID}" )
if ! echo "$_verify" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "❌ CF Token 或 Zone ID 无效，请检查后重试:"
    echo "$_verify" | jq -r '.errors[].message' 2>/dev/null || echo "$_verify"
    exit 1
fi
echo "✅ CF 凭据验证通过"

# 查找已有A记录
_list=$( _cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}" )
_record_id=$(echo "$_list" | jq -r '.result[0].id // empty')
_old_ip=$(echo "$_list"   | jq -r '.result[0].content // empty')
_payload="{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}"

if [ -n "$_record_id" ]; then
    if [ "$_old_ip" = "$IP" ]; then
        echo "✅ DNS记录已是最新，无需更新 ($DOMAIN → $IP)"
    else
        echo "🔄 更新A记录: $_old_ip → $IP"
        _resp=$( _cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${_record_id}" "$_payload" )
        if echo "$_resp" | jq -e '.success == true' >/dev/null 2>&1; then
            echo "✅ DNS A 记录更新成功 (TTL=60s)"
        else
            echo "❌ 更新失败:"; echo "$_resp" | jq -r '.errors[].message' 2>/dev/null; exit 1
        fi
    fi
else
    echo "➕ 新建A记录: $DOMAIN → $IP"
    _resp=$( _cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$_payload" )
    if echo "$_resp" | jq -e '.success == true' >/dev/null 2>&1; then
        echo "✅ DNS A 记录创建成功 (TTL=60s)"
    else
        echo "❌ 创建失败:"; echo "$_resp" | jq -r '.errors[].message' 2>/dev/null; exit 1
    fi
fi

# 立即清除Token和ZoneID（不再需要）
unset CF_TOKEN CF_ZONE_ID _cf_api

# 等待DNS生效（ACME签发前需要域名指向本机）
echo "⏳ 等待DNS生效（最多90秒，ACME签证书依赖此步骤）..."
_resolved=""
for _i in $(seq 1 18); do
    sleep 5
    _resolved=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    if [ "$_resolved" = "$IP" ]; then
        echo "✅ DNS已生效: $DOMAIN → $IP"
        break
    fi
    printf "  %ds 等待中... (当前解析: %s)\n" "$((_i*5))" "${_resolved:-未解析}"
done
if [ "$_resolved" != "$IP" ]; then
    echo "⚠️  90秒内未解析到本机，可能仍在传播。继续安装，若ACME签发失败请稍后重试。"
fi

# ================================================================
# 放行防火墙端口
# ================================================================
iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80            -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT     -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
ufw disable >/dev/null 2>&1 || true

# 端口占用检查
for prt in "$RAND_PORT" 80; do
    if ss -tlnp 2>/dev/null | grep -q ":$prt "; then
        echo "❌ $prt 端口被其他进程占用，请先停掉再重试"; exit 1
    fi
done

# 固定Token（协议+节点名+IP+盐，算完即unset盐）
SUB_TOKEN=$(echo -n "${NODE_NAME}-${PROTO}-${IP}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
unset SUB_SALT
echo "$SUB_TOKEN" > /etc/s-box/sub_token
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# ================================================================
# 下载 sing-box
# ================================================================
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "正在下载 sing-box v$SB_VER ..."
    wget -O /etc/s-box/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
else
    echo "✅ sing-box v$SB_VER 已安装"
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box 安装失败"; exit 1; }

# ================================================================
# 认证凭据持久化：VLESS用UUID，Trojan用随机密码
# ================================================================
if [ "$PROTO" = "vless" ]; then
    if [ -f /etc/s-box/uuid ]; then
        uuid=$(cat /etc/s-box/uuid)
        echo "✅ 复用已有UUID: ${uuid:0:8}********"
    else
        uuid=$(/etc/s-box/sing-box generate uuid)
        echo "$uuid" > /etc/s-box/uuid
        echo "✅ 生成新UUID: ${uuid:0:8}********"
    fi
else
    if [ -f /etc/s-box/trojan_pass ]; then
        tpass=$(cat /etc/s-box/trojan_pass)
        echo "✅ 复用已有Trojan密码: ${tpass:0:4}********"
    else
        tpass=$(/etc/s-box/sing-box generate rand --hex 16)
        echo "$tpass" > /etc/s-box/trojan_pass
        echo "✅ 生成新Trojan密码: ${tpass:0:4}********"
    fi
fi

# ================================================================
# sing-box 配置（按协议生成，内置ACME，禁UDP）
# ================================================================
if [ "$PROTO" = "vless" ]; then
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "proxy-in",
      "listen": "0.0.0.0",
      "listen_port": $RAND_PORT,
      "users": [
        { "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "acme": {
          "domain": ["$DOMAIN"],
          "email": "$ACME_EMAIL",
          "data_directory": "/etc/s-box/acme"
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
else
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "proxy-in",
      "listen": "0.0.0.0",
      "listen_port": $RAND_PORT,
      "users": [
        { "password": "$tpass" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "acme": {
          "domain": ["$DOMAIN"],
          "email": "$ACME_EMAIL",
          "data_directory": "/etc/s-box/acme"
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
fi

/etc/s-box/sing-box check -c "$CONF_PATH" || { echo "❌ 配置校验失败"; exit 1; }

# ================================================================
# systemd 服务
# ================================================================
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Proxy TLS Service
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
echo "⏳ 等待 ACME 首次签发证书（约5-30秒）..."
sleep 8

# ================================================================
# 订阅 HTTP 服务
# ================================================================
cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription HTTP server
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

# ================================================================
# 生成订阅 proxy.yaml
# ================================================================
gen_sub() {
    local token name_val port_val
    name_val=$(cat /etc/s-box/node_name)
    token=$(cat /etc/s-box/sub_token)
    port_val=$(cat /etc/s-box/listen_port)
    if [ "$PROTO" = "vless" ]; then
        cat > "${SUB_YAML_ROOT}/${token}/proxy.yaml" <<YAML
proxies:
  - name: "$name_val-$IP"
    type: vless
    server: $IP
    port: $port_val
    uuid: $uuid
    network: tcp
    udp: false
    tls: true
    servername: $DOMAIN
    flow: xtls-rprx-vision
    client-fingerprint: chrome
YAML
    else
        cat > "${SUB_YAML_ROOT}/${token}/proxy.yaml" <<YAML
proxies:
  - name: "$name_val-$IP"
    type: trojan
    server: $IP
    port: $port_val
    password: $tpass
    network: tcp
    udp: false
    sni: $DOMAIN
    client-fingerprint: chrome
YAML
    fi
    echo "✅ 订阅已生成: $name_val-$IP ($PROTO $DOMAIN:$port_val)"
}
gen_sub

# ================================================================
# nb 快捷命令
# ================================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
      || curl -s4m5 https://icanhazip.com 2>/dev/null \
      || hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]'); [ -z "$IP" ] && IP="<填服务器IP>"
    proto=$(cat /etc/s-box/protocol 2>/dev/null || echo "vless")
    dom=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mod_status=$(lsmod | grep -q bbr \
        && echo -e "\033[32m已加载\033[0m" \
        || echo -e "\033[31m未加载\033[0m")

    cert_ok="未知"
    if echo | timeout 5 openssl s_client \
            -connect "127.0.0.1:$p" -servername "$dom" 2>/dev/null \
            | grep -q "Verify return code: 0"; then
        cert_ok="\033[32m有效\033[0m"
    else
        cert_ok="\033[33m签发中 / journalctl -u sing-box\033[0m"
    fi

    echo "==============================================="
    printf "节点名称: \033[36m%s-%s\033[0m\n" "$node_name" "$IP"
    printf "协议:     \033[36m%s\033[0m\n" "$proto"
    printf "监听端口: \033[36m%s\033[0m\n" "$p"
    printf "伪装域名: \033[36m%s\033[0m   证书: %b\n" "$dom" "$cert_ok"
    printf "拥塞算法: \033[32m%s\033[0m  队列: \033[32m%s\033[0m  BBR: %b\n" \
           "$cc" "$qdisc" "$mod_status"
    echo "==============================================="
    echo "📋 Clash 节点配置"
    echo "==============================================="

    if [ "$proto" = "vless" ]; then
        u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
        link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$dom&fp=chrome&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: vless\n    server: %s\n    port: %s\n" \
               "$node_name" "$IP" "$IP" "$p"
        printf "    uuid: %s\n    network: tcp\n    udp: false\n    tls: true\n" "$u"
        printf "    servername: %s\n    flow: xtls-rprx-vision\n    client-fingerprint: chrome\n" "$dom"
        echo "-----------------------------------------------"
        echo "🔗 VLESS 分享链接 / 二维码"
        echo -e "\033[32m$link\033[0m"
        qrencode -t ansiutf8 "$link"
    else
        tp=$(jq -r '.inbounds[0].users[0].password' "$CP")
        link="trojan://$tp@$IP:$p?security=tls&sni=$dom&fp=chrome&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: trojan\n    server: %s\n    port: %s\n" \
               "$node_name" "$IP" "$IP" "$p"
        printf "    password: %s\n    network: tcp\n    udp: false\n    sni: %s\n" "$tp" "$dom"
        printf "    client-fingerprint: chrome\n"
        echo "-----------------------------------------------"
        echo "🔗 Trojan 分享链接 / 二维码"
        echo -e "\033[32m$link\033[0m"
        qrencode -t ansiutf8 "$link"
    fi

    echo "==============================================="
    echo "📡 HTTP 订阅链接"
    echo -e "\033[33m$SUB_LINK\033[0m"
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
      url: http://cp.cloudflare.com/generate_204
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
      url: http://cp.cloudflare.com/generate_204
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

# ================================================================
# 完成
# ================================================================
echo -e "\n===================== 安装完成 ====================="
echo "协议: $PROTO | 域名: $DOMAIN | 端口: $RAND_PORT"
echo "CF Token/ZoneID/SUB_SALT 均未写入服务器，本次会话结束后自动消失。"
echo ""
echo "常用命令："
echo "  nb                          查看节点/订阅/二维码"
echo "  journalctl -u sing-box -n30 证书签发日志"
echo "  bash 本脚本                 换协议/换端口/换域名"
echo "======================================================"
/usr/local/bin/nb
