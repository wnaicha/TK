#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS/Trojan + TLS (自有域名) V6.0
#  - 安装时二选一协议：VLESS+Vision 或 Trojan
#  - 用你自己的子域名 + Let's Encrypt 证书（sing-box内置ACME，自动续期）
#  - 支持自定义监听端口（不再写死443，应对443被墙/被封场景）
#  - 域名/邮箱/UUID或密码/端口/协议 全部持久化：重装后客户端零改动
#  - 保留：禁UDP / BBR / 固定Token / 节点名带IP / HTTP订阅
# 适配 sing-box 1.13.13 | Debian / Ubuntu
#
# 注意：Let's Encrypt 的 HTTP-01 验证依然需要 80 端口可达，
# 这个和你的代理监听端口是两回事，只在签证书时短暂使用。
# ===============================================================

SB_VER="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080
SUB_YAML_ROOT="/etc/s-box/sub"

# ⚠️ 固定盐：决定订阅Token，改成你自己的随机串，所有机器统一、勿外泄
SUB_SALT="CHANGE-ME-请改成你自己的随机密码-abc123XYZ"

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

# --- 4. 协议 / 节点名 / 域名 / 邮箱 / 端口 / 密钥 持久化 ---
echo "==============================================="
echo "TikTok矩阵 VLESS/Trojan 自有域名版 V6.0"
echo "==============================================="

# ---- 协议选择 ----
OLD_PROTO=$(cat /etc/s-box/protocol 2>/dev/null || echo "")
if [ -n "$OLD_PROTO" ]; then
    echo "当前已安装协议: $OLD_PROTO"
    read -r -p "选择协议 [1]VLESS+Vision [2]Trojan (旧值:$OLD_PROTO，回车保留): " INPUT_PROTO
else
    read -r -p "选择协议 [1]VLESS+Vision [2]Trojan (回车默认1): " INPUT_PROTO
fi
case "$INPUT_PROTO" in
    1) PROTO="vless" ;;
    2) PROTO="trojan" ;;
    "") PROTO="${OLD_PROTO:-vless}" ;;
    vless|trojan) PROTO="$INPUT_PROTO" ;;
    *) echo "❌ 输入无效，只能选 1 或 2"; exit 1 ;;
esac
echo "$PROTO" > /etc/s-box/protocol
echo "✅ 本次安装协议: $PROTO"

OLD_NAME=$(cat /etc/s-box/node_name 2>/dev/null || echo "")
if [ -n "$OLD_NAME" ]; then
    read -r -p "节点名称(旧值:$OLD_NAME，回车保留): " INPUT_NAME
    NODE_NAME="${INPUT_NAME:-$OLD_NAME}"
else
    read -r -p "输入自定义节点名称: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="TK-matrix"
fi
echo "$NODE_NAME" > /etc/s-box/node_name

OLD_DOMAIN=$(cat /etc/s-box/domain 2>/dev/null || echo "")
if [ -n "$OLD_DOMAIN" ]; then
    read -r -p "你的子域名(旧值:$OLD_DOMAIN，回车保留): " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-$OLD_DOMAIN}"
else
    read -r -p "输入你解析到本机的子域名 (如 us1.yourdomain.com): " DOMAIN
fi
[ -z "$DOMAIN" ] && { echo "❌ 必须填子域名"; exit 1; }
echo "$DOMAIN" > /etc/s-box/domain

OLD_EMAIL=$(cat /etc/s-box/acme_email 2>/dev/null || echo "")
if [ -n "$OLD_EMAIL" ]; then
    ACME_EMAIL="$OLD_EMAIL"
else
    read -r -p "ACME邮箱(回车默认 admin@$DOMAIN): " ACME_EMAIL
    [ -z "$ACME_EMAIL" ] && ACME_EMAIL="admin@$DOMAIN"
fi
echo "$ACME_EMAIL" > /etc/s-box/acme_email

# ---- 自定义监听端口（代理端口，不是80） ----
OLD_PORT=$(cat /etc/s-box/listen_port 2>/dev/null || echo "")
if [ -n "$OLD_PORT" ]; then
    read -r -p "代理监听端口(旧值:$OLD_PORT，回车保留): " INPUT_PORT
    RAND_PORT="${INPUT_PORT:-$OLD_PORT}"
else
    read -r -p "代理监听端口(回车默认443，可改成如8443/2053/2083/2087/2096等常见放行端口): " INPUT_PORT
    RAND_PORT="${INPUT_PORT:-443}"
fi
case "$RAND_PORT" in
    ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1 ;;
esac
if [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; then
    echo "❌ 端口范围必须在 1-65535"; exit 1
fi
if [ "$RAND_PORT" = "80" ] || [ "$RAND_PORT" = "$SUB_PORT" ]; then
    echo "❌ 该端口与ACME签证书(80)或订阅服务($SUB_PORT)冲突，请换一个"; exit 1
fi
echo "$RAND_PORT" > /etc/s-box/listen_port
echo "✅ 代理端口设置为: $RAND_PORT"

# 放行 代理端口 / 80(ACME证书签发，固定不可改) / 8080(订阅)
iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80   -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
ufw disable >/dev/null 2>&1 || true

# 端口占用检查（代理端口 + 80，ACME必须用80签发）
for prt in "$RAND_PORT" 80; do
  if ss -tlnp 2>/dev/null | grep -q ":$prt "; then
    echo "❌ $prt 端口被其他进程占用，请先停掉再重试"; exit 1
  fi
done

# 公网IP（用于固定Token、订阅、节点名）
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 取不到公网IP"; exit 1; }

# 校验域名是否解析到本机（仅警告，不强制）
RES_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1)
if [ -n "$RES_IP" ] && [ "$RES_IP" != "$IP" ]; then
    echo "⚠️  注意：$DOMAIN 当前解析到 $RES_IP，但本机是 $IP。"
    echo "    证书签发(HTTP-01)要求域名解析到本机，否则会失败。请先把A记录指过来。"
    read -r -p "已确认解析正确? 回车继续 / Ctrl+C 退出: " _
fi

# 固定Token（带上协议，VLESS和Trojan各自不同token，互不冲突）
SUB_TOKEN=$(echo -n "${NODE_NAME}-${PROTO}-${IP}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
echo "$SUB_TOKEN" > /etc/s-box/sub_token
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# --- 5. 下载 sing-box ---
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "正在下载 sing-box v$SB_VER ..."
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
else
    echo "✅ sing-box v$SB_VER 已安装"
fi
/etc/s-box/sing-box version >/dev/null 2>&1 || { echo "❌ sing-box 安装失败"; exit 1; }

# --- 6. 认证凭据持久化：VLESS用uuid，Trojan用密码 ---
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

# --- 7. sing-box 配置：按协议生成 inbound，TLS+内置ACME（自动签发&续期），禁UDP ---
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

if ! /etc/s-box/sing-box check -c "$CONF_PATH"; then
    echo "❌ 配置校验失败，已中止"; exit 1
fi

# --- 8. systemd 服务 ---
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

echo "⏳ 正在向 Let's Encrypt 申请证书（首次约5-30秒，需80端口可达）..."
sleep 8

# --- 9. 订阅 HTTP 服务 ---
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

# --- 10. 生成订阅（按协议生成对应Clash proxies，端口/域名跟随配置） ---
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
    echo "✅ 订阅文件已生成 $name_val-$IP ($PROTO, $DOMAIN:$port_val)"
}
gen_sub

# --- 11. nb 快捷命令 ---
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    IP=$(echo "$IP" | tr -d '[:space:]'); [ -z "$IP" ] && IP="<填服务器IP>"
    proto=$(cat /etc/s-box/protocol 2>/dev/null || echo "vless")
    dom=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mod_status=$(lsmod | grep -q bbr && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m")

    cert_ok="未知"
    if echo | timeout 5 openssl s_client -connect 127.0.0.1:$p -servername "$dom" 2>/dev/null | grep -q "Verify return code: 0"; then
        cert_ok="\033[32m有效\033[0m"
    else
        cert_ok="\033[33m签发中/检查 journalctl -u sing-box\033[0m"
    fi

    echo "==============================================="
    printf "节点名称: \033[36m%s-$IP\033[0m\n" "$node_name"
    printf "协议:     \033[36m%s\033[0m\n" "$proto"
    printf "监听端口: \033[36m%s\033[0m\n" "$p"
    printf "伪装域名: \033[36m%s\033[0m   证书: %b\n" "$dom" "$cert_ok"
    printf "拥塞算法: \033[32m%s\033[0m  队列: \033[32m%s\033[0m  BBR: %b\n" "$cc" "$qdisc" "$mod_status"
    echo "==============================================="
    echo "📋 Clash 节点配置"
    echo "==============================================="

    if [ "$proto" = "vless" ]; then
        u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
        link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$dom&fp=chrome&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-$IP\"\n" "$node_name"
        printf "    type: vless\n"
        printf "    server: %s\n" "$IP"
        printf "    port: %s\n" "$p"
        printf "    uuid: %s\n" "$u"
        printf "    network: tcp\n"
        printf "    udp: false\n"
        printf "    tls: true\n"
        printf "    servername: %s\n" "$dom"
        printf "    flow: xtls-rprx-vision\n"
        printf "    client-fingerprint: chrome\n"
        echo "-----------------------------------------------"
        echo "🔗 VLESS分享链接 / 二维码"
        echo -e "\033[32m$link\033[0m"
        qrencode -t ansiutf8 "$link"
    else
        tp=$(jq -r '.inbounds[0].users[0].password' "$CP")
        link="trojan://$tp@$IP:$p?security=tls&sni=$dom&fp=chrome&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-$IP\"\n" "$node_name"
        printf "    type: trojan\n"
        printf "    server: %s\n" "$IP"
        printf "    port: %s\n" "$p"
        printf "    password: %s\n" "$tp"
        printf "    network: tcp\n"
        printf "    udp: false\n"
        printf "    sni: %s\n" "$dom"
        printf "    client-fingerprint: chrome\n"
        echo "-----------------------------------------------"
        echo "🔗 Trojan分享链接 / 二维码"
        echo -e "\033[32m$link\033[0m"
        qrencode -t ansiutf8 "$link"
    fi

    echo "==============================================="
    echo "📡 HTTP订阅链接"
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

# --- 完成 ---
echo -e "\n===================== 安装完成 ====================="
echo "协议: $PROTO + TLS（自有域名 $DOMAIN，端口 $RAND_PORT，证书自动续期）"
echo "1. 查看节点/订阅/二维码: nb"
echo "2. 证书/服务日志:        journalctl -u sing-box -n 30"
echo "3. 换协议/改端口：再次运行本脚本，对应步骤输入新值即可（域名不变，旧凭据各自保留互不影响）"
echo "※ 证书由 sing-box 内置 ACME 自动签发与续期，无需手动操作。"
echo "※ 若证书签发失败：确认 $DOMAIN 已解析到本机、80端口可达（80端口和你的代理端口是两回事）。"
echo "===================================================="
/usr/local/bin/nb
