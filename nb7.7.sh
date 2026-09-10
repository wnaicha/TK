#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS + REALITY + Vision (原生直连终极加固版)
#   [架构] 采用直连最优解：VLESS + REALITY + Vision (无须域名/无惧封锁)
#   [安全 1] 运行用户：专用非 root 用户 (sbxuser) + CAP_NET_BIND_SERVICE
#   [安全 2] 完整性校验：下载 sing-box 时校验官方 API 提供的 SHA256
#   [安全 3] Python 订阅服务安全加固：锁定 /etc/s-box/sub 目录，防路径穿越
#   [性能 4] 吞吐优先网络 Stack 调优 (BBR/FQ + 进程/IO 调度 + sysctl 大缓冲区)
#   [运维 5] 自动化维护：systemd timer 每日 0 点定时重启
# 适配 Debian / Ubuntu
# ===============================================================

SB_VER_FALLBACK="1.13.13"
CONF_PATH="/etc/s-box/sb.json"
SUB_PORT=8080
SUB_YAML_ROOT="/etc/s-box/sub"
SBX_USER="sbxuser"

# --- 0. 前置检查与依赖 ---
[ "$(id -u)" != "0" ] && { echo "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "本脚本仅支持 Debian/Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq jq socat curl wget openssl tar chrony qrencode \
    iproute2 python3 iptables-persistent dnsutils libcap2-bin

systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# --- 1. 吞吐优先网络 stack 调优 (BBR/FQ + 大缓冲区) ---
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d;/^net\.ipv4\.tcp_fastopen/d;/^net\.ipv4\.tcp_window_scaling/d;/^net\.ipv4\.tcp_mtu_probing/d;/^net\.ipv6\.conf\.all\.disable_ipv6/d;/^net\.ipv6\.conf\.default\.disable_ipv6/d;/^net\.ipv4\.tcp_rmem/d;/^net\.ipv4\.tcp_wmem/d;/^net\.core\.rmem_max/d;/^net\.core\.wmem_max/d;/^fs\.file-max/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<CONF
fs.file-max=1048576
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
CONF
modprobe tcp_bbr 2>/dev/null || true
sysctl -p >/dev/null 2>&1 || true

_iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
if [ -n "$_iface" ]; then
    tc qdisc replace dev "$_iface" root fq 2>/dev/null \
        && echo "  ✅ 出口网卡 fq 已生效" \
        || echo "  ⚠️  tc qdisc 设置失败，重启后生效"
fi
unset _iface

# --- 2. 目录与架构 ---
mkdir -p /etc/s-box /etc/s-box/sub
case "$(uname -m)" in
    x86_64|amd64)  cpu="amd64" ;;
    aarch64|arm64) cpu="arm64" ;;
    armv7l|armv7)  cpu="armv7" ;;
    *) echo "不支持CPU架构: $(uname -m)"; exit 1 ;;
esac

# --- 3. 停旧服务 ---
systemctl stop sing-box sing-box-restart.timer sb-sub nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
systemctl daemon-reload
sleep 1

# --- 4. 创建专用非root用户 ---
if ! id -u "$SBX_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SBX_USER"
    echo "  ✅ 已创建专用运行用户: $SBX_USER"
else
    echo "  ✅ 运行用户 $SBX_USER 已存在，复用"
fi

# ================================================================
# 工具函数
# ================================================================

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
    printf -v "$_outvar" '%s' "$_val"
}

read_secret() {
    local _outvar="$1" _prompt="$2" _envvar="$3" _val
    if [ -n "${!_envvar}" ]; then
        _val="${!_envvar}"
        echo "  ✅ $_envvar（环境变量传入）"
    else
        read -r -s -p "  $_prompt（不回显）: " _val; echo ""
        [ -z "$_val" ] && { echo "❌ $_prompt 不能为空"; exit 1; }
    fi
    printf -v "$_outvar" '%s' "$_val"
}

# ================================================================
# 配置收集
# ================================================================
echo ""
echo "=========================================="
echo " TikTok矩阵 VLESS+REALITY+Vision 部署"
echo "=========================================="

echo ""
echo "▸ 1. 参数设置"
read_secret SUB_SALT "SUB_SALT 订阅盐值" "SUB_SALT"
read_val NODE_NAME  "节点名称"           /etc/s-box/node_name  "NODE_NAME"  "TK-US-Reality"

# --- REALITY SNI 候选检测 ---
REALITY_SNI_CANDIDATES=(
    "www.icloud.com"
    "www.apple.com"
    "itunes.apple.com"
    "www.microsoft.com"
    "www.cloudflare.com"
    "www.google.com"
)

test_sni_domain() {
    local domain="$1"
    local out rc

    out=$(timeout 5 openssl s_client \
        -connect "${domain}:443" \
        -servername "${domain}" \
        -tls1_3 \
        -verify_return_error </dev/null 2>&1) || rc=$?

    rc=${rc:-0}

    # 不依赖 OpenSSL 是否输出 Protocol 字段。
    # 只要 TLS 1.3 握手成功且证书验证返回 0，即认为基础 SNI 连通性可用。
    if [ "$rc" -eq 0 ] && \
       echo "$out" | grep -Eq 'Verify return code:[[:space:]]*0 \(ok\)'; then
        return 0
    fi

    return 1
}

echo ""
echo "▸ 2. 检测 REALITY SNI 候选域名"
echo "  正在测试当前 VPS 到候选域名的 TLS 1.3 / 证书验证..."
echo ""

SNI_OK_LIST=()
SNI_LATENCY_LIST=()

for domain in "${REALITY_SNI_CANDIDATES[@]}"; do
    start_ms=$(date +%s%3N 2>/dev/null || echo 0)
    if test_sni_domain "$domain"; then
        end_ms=$(date +%s%3N 2>/dev/null || echo "$start_ms")
        if [ "$start_ms" -gt 0 ] 2>/dev/null && [ "$end_ms" -ge "$start_ms" ] 2>/dev/null; then
            latency=$((end_ms - start_ms))
        else
            latency="-"
        fi
        SNI_OK_LIST+=("$domain")
        SNI_LATENCY_LIST+=("$latency")
        printf "  \033[32m✅ %-28s TLS1.3 / Verify OK / %sms\033[0m\n" "$domain" "$latency"
    else
        printf "  \033[31m❌ %-28s TLS1.3 或证书验证失败\033[0m\n" "$domain"
    fi
done

if [ "${#SNI_OK_LIST[@]}" -eq 0 ]; then
    echo ""
    echo "❌ 没有检测到可用的 REALITY SNI 候选域名。"
    echo "   请检查 VPS 出口网络、DNS、时间同步或 443/TCP 连通性。"
    exit 1
fi

echo ""
echo "可用候选："
for i in "${!SNI_OK_LIST[@]}"; do
    printf "  %d) %-28s %sms\n" "$((i+1))" "${SNI_OK_LIST[$i]}" "${SNI_LATENCY_LIST[$i]}"
done

echo ""
while true; do
    read -r -p "请选择 REALITY SNI [1-${#SNI_OK_LIST[@]}]（默认1）: " sni_choice
    sni_choice="${sni_choice:-1}"
    case "$sni_choice" in
        ''|*[!0-9]*) echo "  ❌ 请输入数字"; continue ;;
    esac
    if [ "$sni_choice" -ge 1 ] && [ "$sni_choice" -le "${#SNI_OK_LIST[@]}" ]; then
        SNI_DOMAIN="${SNI_OK_LIST[$((sni_choice-1))]}"
        break
    fi
    echo "  ❌ 选择范围不正确"
done

echo "$SNI_DOMAIN" > /etc/s-box/sni_domain
echo "  ✅ 已选择 REALITY SNI: $SNI_DOMAIN"

read_val RAND_PORT  "代理监听端口"       /etc/s-box/listen_port "PORT"      "443"

case "$RAND_PORT" in ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1 ;; esac
{ [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; } && { echo "❌ 端口范围1-65535"; exit 1; }
[ "$RAND_PORT" = "$SUB_PORT" ] && { echo "❌ 代理端口不能与订阅端口($SUB_PORT)冲突"; exit 1; }

echo ""
echo "▸ 3. sing-box 内核版本"
OLD_SB_VER=$(cat /etc/s-box/sb_version 2>/dev/null || echo "")
if [ -n "$OLD_SB_VER" ]; then
    SB_VER="$OLD_SB_VER"
    echo "  ✅ 复用已安装版本: v$SB_VER"
else
    echo "  🔍 查询 GitHub 最新版本..."
    LATEST=$(curl -s --max-time 8 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
        SB_VER="$LATEST"
        echo "  ✅ 最新版本: v$SB_VER"
    else
        SB_VER="$SB_VER_FALLBACK"
        echo "  ⚠️  查询失败，回落到默认版本: v$SB_VER"
    fi
fi
echo "$SB_VER" > /etc/s-box/sb_version

# ================================================================
# 公网 IP 获取与防火墙
# ================================================================
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 取不到公网IP"; exit 1; }
echo "$IP" > /etc/s-box/server_ip

iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT     -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$RAND_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow $SUB_PORT/tcp     >/dev/null 2>&1 || true
    ufw allow OpenSSH           >/dev/null 2>&1 || true
    echo "  ✅ ufw 规则已追加端口: $RAND_PORT / $SUB_PORT"
fi

SUB_TOKEN=$(echo -n "${NODE_NAME}-reality-${IP}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
unset SUB_SALT
echo "$SUB_TOKEN" > /etc/s-box/sub_token
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# ================================================================
# 下载与校验 sing-box
# ================================================================
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
ASSET_NAME="sing-box-${SB_VER}-linux-${cpu}.tar.gz"
GH_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${ASSET_NAME}"

verify_checksum() {
    local file="$1"
    echo "🔐 校验官方 SHA256..."
    local api_resp expected actual
    api_resp=$(curl -s --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SB_VER}")
    expected=$(echo "$api_resp" | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name==$n) | .digest' 2>/dev/null | sed 's/^sha256://')
    if [ -z "$expected" ] || [ "$expected" = "null" ]; then
        echo "  ⚠️  未获取到官方校验和，跳过校验"
        return 0
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "❌ 校验和不匹配！已删除"
        rm -f "$file"
        exit 1
    fi
    echo "  ✅ 校验和匹配"
}

if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "📦 下载 sing-box v$SB_VER ..."
    if ! wget -T 15 -t 2 -O /etc/s-box/sing-box.tar.gz "$GH_URL" 2>/dev/null; then
        rm -f /etc/s-box/sing-box.tar.gz
        wget -T 30 -O /etc/s-box/sing-box.tar.gz "https://ghp.ci/$GH_URL"
    fi
    verify_checksum /etc/s-box/sing-box.tar.gz
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
fi

# ================================================================
# 密钥与凭据生成
# ================================================================
if [ -f /etc/s-box/uuid ]; then
    uuid=$(cat /etc/s-box/uuid)
else
    uuid=$(/etc/s-box/sing-box generate uuid)
    echo "$uuid" > /etc/s-box/uuid
fi

if [ -f /etc/s-box/reality_privkey ]; then
    priv_key=$(cat /etc/s-box/reality_privkey)
    pub_key=$(cat /etc/s-box/reality_pubkey)
    short_id=$(cat /etc/s-box/reality_shortid)
else
    KEYPAIR=$(/etc/s-box/sing-box generate reality-keypair)
    priv_key=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $2}')
    pub_key=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $2}')
    short_id=$(/etc/s-box/sing-box generate rand --hex 8)

    echo "$priv_key" > /etc/s-box/reality_privkey
    echo "$pub_key"  > /etc/s-box/reality_pubkey
    echo "$short_id" > /etc/s-box/reality_shortid
fi

# ================================================================
# sing-box REALITY 配置生成
# ================================================================
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless",
    "tag": "proxy-in",
    "listen": "0.0.0.0",
    "listen_port": $RAND_PORT,
    "users": [{
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "$SNI_DOMAIN",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "$SNI_DOMAIN",
          "server_port": 443
        },
        "private_key": "$priv_key",
        "short_id": ["$short_id"]
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

/etc/s-box/sing-box check -c "$CONF_PATH" || { echo "❌ 配置校验失败"; exit 1; }

# ================================================================
# 安全订阅 HTTP 服务
# ================================================================
cat > /etc/s-box/sub_server.py <<'PYEOF'
#!/usr/bin/env python3
import http.server
import socketserver
import os
import sys
import posixpath
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
BASE_DIR = os.path.realpath("/etc/s-box/sub")

class SafeHandler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        self.send_error(403, "Access Denied")
        return None

    def translate_path(self, path):
        path = path.split('?', 1)[0].split('#', 1)[0]
        path = urllib.parse.unquote(path)
        path = posixpath.normpath(path)
        candidate = os.path.realpath(os.path.join(BASE_DIR, path.lstrip('/')))
        if candidate != BASE_DIR and not candidate.startswith(BASE_DIR + os.sep):
            return BASE_DIR
        return candidate

    def log_message(self, format, *args):
        pass

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    if not os.path.exists(BASE_DIR):
        os.makedirs(BASE_DIR, exist_ok=True)
    with ReusableTCPServer(("0.0.0.0", PORT), SafeHandler) as httpd:
        httpd.serve_forever()
PYEOF
chmod +x /etc/s-box/sub_server.py

# ================================================================
# Systemd 服务定义
# ================================================================
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Proxy VLESS-REALITY (High Performance)
After=network.target nss-lookup.target chrony.service

[Service]
User=$SBX_USER
Group=$SBX_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
RestartSec=3
NoNewPrivileges=true

Nice=-10
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-500
LimitNOFILE=1048576
LimitMEMLOCK=infinity
LimitNPROC=51200
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription HTTP (safe)
After=network.target

[Service]
User=$SBX_USER
Group=$SBX_USER
WorkingDirectory=/etc/s-box/sub
ExecStart=/usr/bin/python3 /etc/s-box/sub_server.py $SUB_PORT
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sing-box-restart.service <<EOF
[Unit]
Description=Daily Restart Trigger for sing-box Service
After=sing-box.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl try-restart sing-box.service
EOF

cat > /etc/systemd/system/sing-box-restart.timer <<EOF
[Unit]
Description=Daily Midnight Restart Timer for sing-box

[Timer]
OnCalendar=*-*-* 00:00:00
RandomizedDelaySec=15
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ================================================================
# 生成订阅 YAML (Clash Meta 格式)
# ================================================================
_token=$(cat /etc/s-box/sub_token)

cat > "${SUB_YAML_ROOT}/${_token}/proxy.yaml" <<YAML
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $IP
    port: $RAND_PORT
    uuid: $uuid
    network: tcp
    udp: false          # 防原生 WebRTC 真实 IP 泄漏
    tls: true
    flow: xtls-rprx-vision
    servername: $SNI_DOMAIN
    client-fingerprint: safari
    reality-opts:
      public-key: $pub_key
      short-id: $short_id
YAML

# ================================================================
# nb 快捷查询脚本
# ================================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(cat /etc/s-box/server_ip 2>/dev/null)
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    sbver=$(cat /etc/s-box/sb_version 2>/dev/null || echo "未知")
    sn=$(cat /etc/s-box/sni_domain)
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
    pb=$(cat /etc/s-box/reality_pubkey)
    sid=$(cat /etc/s-box/reality_shortid)
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    _iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    qdisc=$(tc qdisc show dev "$_iface" 2>/dev/null | head -1 | awk '{print $2}')
    run_user=$(systemctl show -p User sing-box 2>/dev/null | cut -d= -f2)

    echo "=============================================="
    printf "节点: \033[36m%s\033[0m  架构: \033[36mVLESS+REALITY+Vision\033[0m\n" "$node_name"
    printf "核心: \033[36mv%s\033[0m  监听端口: \033[36m%s\033[0m\n" "$sbver" "$p"
    printf "伪装 SNI: \033[36m%s\033[0m\n" "$sn"
    printf "运行用户: \033[36m%s\033[0m  队列: \033[32m%s\033[0m  拥塞: \033[32m%s\033[0m\n" "$run_user" "$qdisc" "$cc"
    echo "=============================================="
    echo "📋 Clash Meta (Mihomo) 节点配置"
    echo "=============================================="
    printf "  - name: \"%s\"\n    type: vless\n    server: %s\n    port: %d\n" "$node_name" "$IP" "$p"
    printf "    uuid: %s\n    network: tcp\n    udp: false\n    tls: true\n" "$u"
    printf "    flow: xtls-rprx-vision\n    servername: %s\n    client-fingerprint: safari\n" "$sn"
    printf "    reality-opts:\n      public-key: %s\n      short-id: %s\n" "$pb" "$sid"

    link="vless://$u@$IP:$p?type=tcp&security=reality&encryption=none&pbk=$pb&fp=safari&sni=$sn&sid=$sid&flow=xtls-rprx-vision#$node_name"

    echo "----------------------------------------------"
    echo "🔗 分享链接 / 二维码"
    echo -e "\033[32m$link\033[0m"
    qrencode -t ansiutf8 "$link"
    echo "=============================================="
    echo "📡 订阅链接"
    echo -e "\033[33m$SUB_LINK\033[0m"
    echo "=============================================="
}

rm -f /usr/local/bin/nb
{ echo '#!/bin/bash'; declare -f nb_info; echo 'nb_info'; } > /usr/local/bin/nb
chmod +x /usr/local/bin/nb

# ================================================================
# 权限统一收尾 & 启动服务
# ================================================================
# 确保 sing-box 专用用户可以访问整个配置目录
chown -R "$SBX_USER":"$SBX_USER" /etc/s-box

# sing-box 二进制可执行
chmod 755 /etc/s-box/sing-box

# 配置文件不要给其他用户读取（包含私钥与UUID）
chmod 640 /etc/s-box/sb.json

# 订阅目录及其子项权限
chmod 755 /etc/s-box/sub

systemctl daemon-reload
systemctl enable sing-box sb-sub sing-box-restart.timer
systemctl restart sing-box sb-sub sing-box-restart.timer

echo ""
echo "==================== 安装完成 ===================="
echo "协议: VLESS + REALITY + Vision"
echo "伪装域名: $SNI_DOMAIN"
echo "输入 nb 即可随时查看节点参数、二维码与订阅链接"
echo "==================================================="
/usr/local/bin/nb
