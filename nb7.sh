#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS/Trojan + TLS V10.0
# ===============================================================

SB_VER="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080
SUB_YAML_ROOT="/etc/s-box/sub"

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq jq socat curl wget openssl tar chrony qrencode \
    iproute2 python3 iptables-persistent dnsutils

systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# --- 1. BBR/FQ ---
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

# --- 2. 目录与架构 ---
mkdir -p /etc/s-box /etc/s-box/acme
case "$(uname -m)" in
    x86_64|amd64)  cpu="amd64" ;;
    aarch64|arm64) cpu="arm64" ;;
    armv7l|armv7)  cpu="armv7" ;;
    *) echo "不支持CPU架构: $(uname -m)"; exit 1 ;;
esac

# --- 3. 停旧服务 ---
systemctl stop sing-box sb-sub nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
systemctl daemon-reload
sleep 1

# ================================================================
# 工具函数
# ================================================================

# 普通值：环境变量 → 持久化旧值 → 交互输入
read_val() {
    local _outvar="$1" _prompt="$2" _file="$3" _envvar="$4" _default="$5"
    local _val _old
    _old=$(cat "$_file" 2>/dev/null || echo "")
    if [ -n "${!_envvar}" ]; then
        _val="${!_envvar}"
        echo "  ✅ $_envvar = $_val（环境变量）"
    elif [ -n "$_old" ]; then
        read -r -p "  $_prompt (旧值:$_old，回车保留): " _input
        _val="${_input:-$_old}"
    else
        read -r -p "  $_prompt (${_default:+回车默认$_default}): " _input
        _val="${_input:-$_default}"
    fi
    [ -z "$_val" ] && { echo "❌ $_prompt 不能为空"; exit 1; }
    mkdir -p "$(dirname "$_file")"
    echo "$_val" > "$_file"
    eval "$_outvar='$_val'"
}

# 敏感值：环境变量 → 交互输入（不回显，不落盘）
read_secret() {
    local _outvar="$1" _prompt="$2" _envvar="$3" _val
    if [ -n "${!_envvar}" ]; then
        _val="${!_envvar}"
        echo "  ✅ $_envvar（环境变量传入）"
    else
        read -r -s -p "  $_prompt（不回显）: " _val; echo ""
        [ -z "$_val" ] && { echo "❌ $_prompt 不能为空"; exit 1; }
    fi
    eval "$_outvar='$_val'"
}

# ================================================================
# 配置收集
# ================================================================
echo ""
echo "=========================================="
echo " TikTok矩阵 VLESS/Trojan V10.0"
echo "=========================================="

echo ""
echo "▸ 1. 敏感凭据（有环境变量自动跳过）"
read_secret SUB_SALT   "SUB_SALT 订阅盐值"    "SUB_SALT"
read_secret CF_TOKEN   "Cloudflare API Token" "CF_TOKEN"
read_secret CF_ZONE_ID "Cloudflare Zone ID"   "CF_ZONE_ID"

echo ""
echo "▸ 2. 协议"
OLD_PROTO=$(cat /etc/s-box/protocol 2>/dev/null || echo "")
if [ -n "$OLD_PROTO" ]; then
    read -r -p "  选择协议 [1]VLESS+Vision [2]Trojan (旧值:$OLD_PROTO，回车保留): " _p
else
    read -r -p "  选择协议 [1]VLESS+Vision [2]Trojan (回车默认1-VLESS): " _p
fi
case "$_p" in
    1) PROTO="vless" ;;
    2) PROTO="trojan" ;;
    "") PROTO="${OLD_PROTO:-vless}" ;;
    vless|trojan) PROTO="$_p" ;;
    *) echo "❌ 只能选 1 或 2"; exit 1 ;;
esac
echo "$PROTO" > /etc/s-box/protocol
echo "  ✅ 协议: $PROTO"

echo ""
echo "▸ 3. 节点信息"
read_val NODE_NAME "节点名称"     /etc/s-box/node_name   "NODE_NAME" "TK-matrix"
read_val DOMAIN    "子域名"       /etc/s-box/domain      "DOMAIN"    ""
read_val RAND_PORT "代理监听端口" /etc/s-box/listen_port "PORT"      "443"

# ACME邮箱（有旧值复用，没有用域名默认）
OLD_EMAIL=$(cat /etc/s-box/acme_email 2>/dev/null || echo "")
if [ -n "$OLD_EMAIL" ]; then
    ACME_EMAIL="$OLD_EMAIL"
    echo "  ✅ ACME邮箱: $ACME_EMAIL（复用）"
else
    ACME_EMAIL="admin@$DOMAIN"
    echo "$ACME_EMAIL" > /etc/s-box/acme_email
    echo "  ✅ ACME邮箱: $ACME_EMAIL"
fi

echo ""
echo "▸ 4. 证书签发机构"
OLD_CA=$(cat /etc/s-box/acme_ca 2>/dev/null || echo "1")
echo "  [1] Let's Encrypt（默认）"
echo "  [2] ZeroSSL（推荐，速度快）"
echo "  [3] Buypass（备用）"
read -r -p "  选择CA [1-3] (旧值:$OLD_CA，回车保留): " CA_CHOICE
CA_CHOICE="${CA_CHOICE:-$OLD_CA}"
echo "$CA_CHOICE" > /etc/s-box/acme_ca
case "$CA_CHOICE" in
    2) CA_SERVER="https://acme.zerossl.com/v2/DV90"
       echo "  ✅ ZeroSSL" ;;
    3) CA_SERVER="https://api.buypass.com/acme/directory"
       echo "  ✅ Buypass" ;;
    *) CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
       echo "  ✅ Let's Encrypt" ;;
esac

# 端口校验
case "$RAND_PORT" in ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1 ;; esac
{ [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; } && { echo "❌ 端口范围1-65535"; exit 1; }
{ [ "$RAND_PORT" = "80" ] || [ "$RAND_PORT" = "$SUB_PORT" ]; } && { echo "❌ 端口与ACME(80)或订阅($SUB_PORT)冲突"; exit 1; }

# ================================================================
# 公网IP
# ================================================================
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 取不到公网IP"; exit 1; }
echo "$IP" > /etc/s-box/server_ip
echo ""
echo "📡 IP: $IP | 域名: $DOMAIN | 协议: $PROTO | 端口: $RAND_PORT"

# ================================================================
# Cloudflare 自动设置 A 记录
# ================================================================
echo ""
echo "🌐 Cloudflare DNS: $DOMAIN → $IP"
_cf() {
    curl -s -X "$1" "https://api.cloudflare.com/client/v4${2}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        ${3:+--data "$3"}
}

_chk=$(_cf GET "/zones/${CF_ZONE_ID}")
if ! echo "$_chk" | jq -e '.success==true' >/dev/null 2>&1; then
    echo "❌ CF凭据无效:"; echo "$_chk" | jq -r '.errors[].message' 2>/dev/null; exit 1
fi
echo "  ✅ CF凭据验证通过"

_pl="{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}"
_list=$(_cf GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}")
_rid=$(echo "$_list" | jq -r '.result[0].id // empty')
_oip=$(echo "$_list" | jq -r '.result[0].content // empty')

if [ -n "$_rid" ]; then
    if [ "$_oip" = "$IP" ]; then
        echo "  ✅ DNS记录已是最新，跳过"
    else
        _r=$(_cf PUT "/zones/${CF_ZONE_ID}/dns_records/${_rid}" "$_pl")
        echo "$_r" | jq -e '.success==true' >/dev/null 2>&1 \
            && echo "  ✅ 已更新: $_oip → $IP" \
            || { echo "❌ 更新失败"; echo "$_r" | jq -r '.errors[].message'; exit 1; }
    fi
else
    _r=$(_cf POST "/zones/${CF_ZONE_ID}/dns_records" "$_pl")
    echo "$_r" | jq -e '.success==true' >/dev/null 2>&1 \
        && echo "  ✅ 已创建: $DOMAIN → $IP" \
        || { echo "❌ 创建失败"; echo "$_r" | jq -r '.errors[].message'; exit 1; }
fi
unset CF_TOKEN CF_ZONE_ID _cf _chk _pl _list _rid _oip _r

# 等待DNS生效
echo "⏳ 等待DNS生效（最多90秒）..."
for _i in $(seq 1 18); do
    sleep 5
    _res=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    [ "$_res" = "$IP" ] && { echo "  ✅ DNS已生效"; break; }
    printf "  %ds... 当前解析:%s\n" "$((_i*5))" "${_res:-未解析}"
done
[ "$_res" != "$IP" ] && echo "⚠️  DNS仍在传播，继续安装（ACME若失败请稍后重试）"

# ================================================================
# 防火墙
# ================================================================
iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80            -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT     -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
ufw disable >/dev/null 2>&1 || true
for prt in "$RAND_PORT" 80; do
    ss -tlnp 2>/dev/null | grep -q ":$prt " && { echo "❌ $prt 端口被占用"; exit 1; }
done

# 订阅Token（算完立即unset盐）
SUB_TOKEN=$(echo -n "${NODE_NAME}-${PROTO}-${IP}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
unset SUB_SALT
echo "$SUB_TOKEN" > /etc/s-box/sub_token
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# ================================================================
# 下载 sing-box（失败自动切国内镜像）
# ================================================================
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "📦 下载 sing-box v$SB_VER ..."
    GH_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    if ! wget -T 15 -t 2 -O /etc/s-box/sing-box.tar.gz "$GH_URL" 2>/dev/null; then
        echo "  ⚠️  GitHub超时，切换国内镜像..."
        rm -f /etc/s-box/sing-box.tar.gz
        wget -T 30 -O /etc/s-box/sing-box.tar.gz "https://ghp.ci/$GH_URL"
    fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
    echo "  ✅ sing-box v$SB_VER 安装完成"
else
    echo "  ✅ sing-box v$SB_VER 已安装，跳过下载"
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box 安装失败"; exit 1; }

# ================================================================
# 认证凭据持久化
# ================================================================
if [ "$PROTO" = "vless" ]; then
    if [ -f /etc/s-box/uuid ]; then
        uuid=$(cat /etc/s-box/uuid)
        echo "  ✅ 复用UUID: ${uuid:0:8}***"
    else
        uuid=$(/etc/s-box/sing-box generate uuid)
        echo "$uuid" > /etc/s-box/uuid
        echo "  ✅ 新UUID: ${uuid:0:8}***"
    fi
else
    if [ -f /etc/s-box/trojan_pass ]; then
        tpass=$(cat /etc/s-box/trojan_pass)
        echo "  ✅ 复用Trojan密码: ${tpass:0:4}***"
    else
        tpass=$(/etc/s-box/sing-box generate rand --hex 16)
        echo "$tpass" > /etc/s-box/trojan_pass
        echo "  ✅ 新Trojan密码: ${tpass:0:4}***"
    fi
fi

# ================================================================
# sing-box 配置（ALPN h2/http1.1，无skip-cert-verify）
# ================================================================
if [ "$PROTO" = "vless" ]; then
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless", "tag": "proxy-in",
    "listen": "0.0.0.0", "listen_port": $RAND_PORT,
    "users": [{ "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "alpn": ["h2", "http/1.1"],
      "acme": {
        "server": "$CA_SERVER",
        "domain": ["$DOMAIN"],
        "email": "$ACME_EMAIL",
        "data_directory": "/etc/s-box/acme"
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rules": [{ "network": "udp", "action": "reject" }],
    "final": "direct"
  }
}
JSON
else
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "trojan", "tag": "proxy-in",
    "listen": "0.0.0.0", "listen_port": $RAND_PORT,
    "users": [{ "password": "$tpass" }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "alpn": ["h2", "http/1.1"],
      "acme": {
        "server": "$CA_SERVER",
        "domain": ["$DOMAIN"],
        "email": "$ACME_EMAIL",
        "data_directory": "/etc/s-box/acme"
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rules": [{ "network": "udp", "action": "reject" }],
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
Description=sing-box Proxy TLS
After=network.target nss-lookup.target chrony.service
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
RestartSec=3
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription HTTP
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
systemctl enable sing-box sb-sub
systemctl restart sing-box
echo "⏳ 等待ACME签发证书（首次约10-25秒）..."
sleep 15
systemctl restart sb-sub

# ================================================================
# 生成订阅（safari指纹，无skip-cert-verify）
# ================================================================
_token=$(cat /etc/s-box/sub_token)
_port=$(cat /etc/s-box/listen_port)

if [ "$PROTO" = "vless" ]; then
cat > "${SUB_YAML_ROOT}/${_token}/proxy.yaml" <<YAML
proxies:
  - name: "$NODE_NAME-$IP"
    type: vless
    server: $IP
    port: $_port
    uuid: $uuid
    network: tcp
    udp: false
    tls: true
    servername: $DOMAIN
    flow: xtls-rprx-vision
    client-fingerprint: safari
YAML
else
cat > "${SUB_YAML_ROOT}/${_token}/proxy.yaml" <<YAML
proxies:
  - name: "$NODE_NAME-$IP"
    type: trojan
    server: $IP
    port: $_port
    password: $tpass
    network: tcp
    udp: false
    tls: true
    sni: $DOMAIN
    client-fingerprint: safari
YAML
fi
echo "  ✅ 订阅已生成: $NODE_NAME-$IP ($PROTO $DOMAIN:$_port)"

# ================================================================
# nb 快捷命令
# ================================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(cat /etc/s-box/server_ip 2>/dev/null || \
         curl -s4m5 https://api.ipify.org 2>/dev/null || \
         hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]')
    proto=$(cat /etc/s-box/protocol 2>/dev/null || echo "vless")
    dom=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    ca=$(cat /etc/s-box/acme_ca 2>/dev/null || echo "1")
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    bbr=$(lsmod | grep -q bbr \
        && echo -e "\033[32m已加载\033[0m" \
        || echo -e "\033[31m未加载\033[0m")
    case "$ca" in
        2) ca_name="ZeroSSL" ;;
        3) ca_name="Buypass" ;;
        *) ca_name="Let's Encrypt" ;;
    esac

    cert="未知"
    echo | timeout 5 openssl s_client \
        -connect "127.0.0.1:$p" -servername "$dom" -alpn h2 2>/dev/null \
        | grep -q "Verify return code: 0" \
        && cert="\033[32m有效\033[0m" \
        || cert="\033[33m签发中 / journalctl -u sing-box\033[0m"

    echo "=============================================="
    printf "节点: \033[36m%s-%s\033[0m  协议: \033[36m%s\033[0m\n" "$node_name" "$IP" "$proto"
    printf "端口: \033[36m%s\033[0m  域名: \033[36m%s\033[0m\n" "$p" "$dom"
    printf "证书: %b  CA: \033[36m%s\033[0m\n" "$cert" "$ca_name"
    printf "BBR:  %b  队列: \033[32m%s\033[0m  拥塞: \033[32m%s\033[0m\n" "$bbr" "$qdisc" "$cc"
    echo "=============================================="
    echo "📋 Clash 节点配置"
    echo "=============================================="

    if [ "$proto" = "vless" ]; then
        u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
        link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$dom&fp=safari&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: vless\n    server: %s\n    port: %s\n" \
               "$node_name" "$IP" "$IP" "$p"
        printf "    uuid: %s\n    network: tcp\n    udp: false\n    tls: true\n" "$u"
        printf "    servername: %s\n    flow: xtls-rprx-vision\n    client-fingerprint: safari\n" "$dom"
    else
        tp=$(jq -r '.inbounds[0].users[0].password' "$CP")
        link="trojan://$tp@$IP:$p?security=tls&sni=$dom&fp=safari&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: trojan\n    server: %s\n    port: %s\n" \
               "$node_name" "$IP" "$IP" "$p"
        printf "    password: %s\n    network: tcp\n    udp: false\n    tls: true\n" "$tp"
        printf "    sni: %s\n    client-fingerprint: safari\n" "$dom"
    fi

    echo "----------------------------------------------"
    echo "🔗 分享链接 / 二维码"
    echo -e "\033[32m$link\033[0m"
    qrencode -t ansiutf8 "$link"
    echo "=============================================="
    echo "📡 订阅链接"
    echo -e "\033[33m$SUB_LINK\033[0m"
    echo "=============================================="
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
{ echo '#!/bin/bash'; declare -f nb_info; echo 'nb_info'; } > /usr/local/bin/nb
chmod +x /usr/local/bin/nb

echo ""
echo "==================== 安装完成 ===================="
echo "协议:$PROTO  域名:$DOMAIN  端口:$RAND_PORT  指纹:safari"
echo "CA:$ca_name  skip-cert-verify:已移除 ✅"
echo "CF Token/ZoneID/SUB_SALT 均未写入服务器 ✅"
echo "==================================================="
/usr/local/bin/nb
