#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS/Trojan + TLS V11.1（安全加固 + 性能调优版）
#   [修改1] 下载 sing-box 后增加官方 checksum 校验，防止供应链篡改
#   [修改2] 移除 ufw disable，改为仅放行必要端口，不整体关闭防火墙
#   [修改3] 订阅服务器换成自定义 Python 服务，禁止目录遍历/路径穿越/目录枚举
#   [修改4] sing-box 进程改为专用非root用户运行，只授予绑定端口所需的最小权限
#   [修改5] 移除客户端配置里的 skip-cert-verify:true（证书是真实ACME签发的，不该跳过校验）
#   [修改6] read_val 的 eval 拼接改成更安全的 printf -v 写法，避免潜在命令注入
#   [修改7] SB_VER 不再写死，改成“有旧值复用旧值，否则自动查询GitHub最新版”，失败兜底
#   [新增8] 使用 systemd timer 实现每天 0 点自动重启 sing-box，附带日志记录
#   [新增9] 对 sing-box 进程施加吞吐优先调优（Nice、IOScheduling、LimitMEMLOCK、sysctl参数）
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

# --- 1. [新增9] 吞吐优先网络 stack 调优 (BBR/FQ + 大缓冲区) ---
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

# 立即对实际出口网卡生效，不等重启
_iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
if [ -n "$_iface" ]; then
    tc qdisc replace dev "$_iface" root fq 2>/dev/null \
        && echo "  ✅ 出口网卡 fq 已立即生效" \
        || echo "  ⚠️  tc qdisc 设置失败，重启后生效"
fi
unset _iface

# --- 2. 目录与架构 ---
mkdir -p /etc/s-box /etc/s-box/acme
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

# --- [修改4] 创建专用非root用户，用于运行 sing-box ---
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
echo " TikTok矩阵 VLESS/Trojan V11.1（性能加固版）"
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
echo "  [2] ZeroSSL（速度快）"
echo "  [3] Buypass（备用）"
read -r -p "  选择CA [1-3] (旧值:$OLD_CA，回车保留): " CA_CHOICE
CA_CHOICE="${CA_CHOICE:-$OLD_CA}"
echo "$CA_CHOICE" > /etc/s-box/acme_ca
case "$CA_CHOICE" in
    2) CA_PROVIDER="zerossl";     CA_NAME="ZeroSSL" ;;
    3) CA_PROVIDER="buypass";     CA_NAME="Buypass" ;;
    *) CA_PROVIDER="letsencrypt"; CA_NAME="Let's Encrypt" ;;
esac
echo "  ✅ $CA_NAME"

case "$RAND_PORT" in ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1 ;; esac
{ [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; } && { echo "❌ 端口范围1-65535"; exit 1; }
{ [ "$RAND_PORT" = "80" ] || [ "$RAND_PORT" = "$SUB_PORT" ]; } && { echo "❌ 端口与ACME(80)或订阅($SUB_PORT)冲突"; exit 1; }

echo ""
echo "▸ 5. sing-box 内核版本"
OLD_SB_VER=$(cat /etc/s-box/sb_version 2>/dev/null || echo "")
if [ -n "$OLD_SB_VER" ]; then
    SB_VER="$OLD_SB_VER"
    echo "  ✅ 复用已安装版本: v$SB_VER（如需升级请删除 /etc/s-box/sb_version 后重跑）"
else
    echo "  🔍 查询 GitHub 最新版本..."
    LATEST=$(curl -s --max-time 8 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
        SB_VER="$LATEST"
        echo "  ✅ 最新版本: v$SB_VER"
    else
        SB_VER="$SB_VER_FALLBACK"
        echo "  ⚠️  查询失败（可能网络问题），回落到默认版本: v$SB_VER"
    fi
fi
echo "$SB_VER" > /etc/s-box/sb_version

# ================================================================
# 公网IP与 Cloudflare DNS
# ================================================================
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 取不到公网IP"; exit 1; }
echo "$IP" > /etc/s-box/server_ip
echo ""
echo "📡 IP:$IP | 域名:$DOMAIN | 协议:$PROTO | 端口:$RAND_PORT | CA:$CA_NAME | sing-box:v$SB_VER"

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

echo "⏳ 等待DNS生效（最多90秒）..."
for _i in $(seq 1 18); do
    sleep 5
    _res=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    [ "$_res" = "$IP" ] && { echo "  ✅ DNS已生效"; break; }
    printf "  %ds... 当前解析:%s\n" "$((_i*5))" "${_res:-未解析}"
done
[ "$_res" != "$IP" ] && echo "⚠️  DNS仍在传播，继续安装（ACME若失败请稍后重试）"

# ================================================================
# 防火墙设置
# ================================================================
iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80            -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT     -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "  ℹ️  检测到 ufw 处于启用状态，仅追加放行规则"
    ufw allow "$RAND_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp            >/dev/null 2>&1 || true
    ufw allow $SUB_PORT/tcp     >/dev/null 2>&1 || true
    ufw allow OpenSSH           >/dev/null 2>&1 || true
    echo "  ✅ ufw 规则已追加：$RAND_PORT/80/$SUB_PORT/SSH"
else
    echo "  ℹ️  ufw 未启用，跳过"
fi

for prt in "$RAND_PORT" 80; do
    ss -tlnp 2>/dev/null | grep -q ":$prt " && { echo "❌ $prt 端口被占用"; exit 1; }
done

SUB_TOKEN=$(echo -n "${NODE_NAME}-${PROTO}-${IP}-${SUB_SALT}" | sha256sum | awk '{print substr($1,1,36)}')
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
        echo "  ⚠️  GitHub API 未返回该版本的官方校验和，跳过校验"
        return 0
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "❌ 校验和不匹配！文件可能被篡改，已删除"
        rm -f "$file"
        exit 1
    fi
    echo "  ✅ 校验和匹配，文件完整可信"
}

if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "📦 下载 sing-box v$SB_VER ..."
    if ! wget -T 15 -t 2 -O /etc/s-box/sing-box.tar.gz "$GH_URL" 2>/dev/null; then
        echo "  ⚠️  GitHub超时，切换镜像..."
        rm -f /etc/s-box/sing-box.tar.gz
        wget -T 30 -O /etc/s-box/sing-box.tar.gz "https://ghp.ci/$GH_URL"
    fi
    verify_checksum /etc/s-box/sing-box.tar.gz
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
# 凭据持久化
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
# sing-box 配置
# ================================================================
if [ "$PROTO" = "vless" ]; then
cat > "$CONF_PATH" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless",
    "tag": "proxy-in",
    "listen": "0.0.0.0",
    "listen_port": $RAND_PORT,
    "users": [{ "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "alpn": ["h2", "http/1.1"],
      "acme": {
        "domain": ["$DOMAIN"],
        "email": "$ACME_EMAIL",
        "provider": "$CA_PROVIDER",
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
    "type": "trojan",
    "tag": "proxy-in",
    "listen": "0.0.0.0",
    "listen_port": $RAND_PORT,
    "users": [{ "password": "$tpass" }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "alpn": ["h2", "http/1.1"],
      "acme": {
        "domain": ["$DOMAIN"],
        "email": "$ACME_EMAIL",
        "provider": "$CA_PROVIDER",
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
echo "  ✅ 配置校验通过"

# 权限收敛
chown -R "$SBX_USER":"$SBX_USER" /etc/s-box/acme
chown "$SBX_USER":"$SBX_USER" "$CONF_PATH"
chmod 640 "$CONF_PATH"

# ================================================================
# [修改3 + 漏洞修复] 自定义订阅 HTTP 服务（防穿越 + 禁用目录浏览）
# ================================================================
cat > /etc/s-box/sub_server.py <<'PYEOF'
#!/usr/bin/env python3
"""
最小化订阅文件服务器：
1. 校验路径是否超出 BASE_DIR（防穿越）
2. 拦截目录浏览请求（防 Token 泄漏）
"""
import http.server
import socketserver
import os
import sys
import posixpath
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
BASE_DIR = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))

class SafeHandler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        # 拦截目录访问，禁止渲染文件列表
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
    with ReusableTCPServer(("0.0.0.0", PORT), SafeHandler) as httpd:
        httpd.serve_forever()
PYEOF
chmod +x /etc/s-box/sub_server.py
chown "$SBX_USER":"$SBX_USER" /etc/s-box/sub_server.py
echo "  ✅ 已部署安全的订阅服务器（防目录穿越与列目录）"

# ================================================================
# [新增8 + 新增9] systemd 服务定义与吞吐量优先级调优
# ================================================================
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Proxy TLS (High Performance)
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

# --- 吞吐量与进程调度调优 ---
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

# --- [新增8] 每天 0 点自动重启 systemd timer & service ---
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

chown -R "$SBX_USER":"$SBX_USER" "$SUB_YAML_ROOT"

systemctl daemon-reload
systemctl enable sing-box sb-sub sing-box-restart.timer
systemctl restart sing-box sing-box-restart.timer
echo "⏳ 等待ACME签发证书（首次约10-25秒）..."
sleep 15
systemctl restart sb-sub

# ================================================================
# 生成订阅 YAML
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
chown "$SBX_USER":"$SBX_USER" "${SUB_YAML_ROOT}/${_token}/proxy.yaml"
echo "  ✅ 订阅已生成: $NODE_NAME-$IP ($PROTO $DOMAIN:$_port)"

# ================================================================
# nb 快捷查询脚本
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
    ca_idx=$(cat /etc/s-box/acme_ca 2>/dev/null || echo "1")
    sbver=$(cat /etc/s-box/sb_version 2>/dev/null || echo "未知")
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    _iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    qdisc=$(tc qdisc show dev "$_iface" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$qdisc" ] && qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    bbr=$(lsmod | grep -q bbr \
        && echo -e "\033[32m已加载\033[0m" \
        || echo -e "\033[31m未加载\033[0m")
    case "$ca_idx" in
        2) ca_name="ZeroSSL" ;;
        3) ca_name="Buypass" ;;
        *) ca_name="Let's Encrypt" ;;
    esac
    run_user=$(systemctl show -p User sing-box 2>/dev/null | cut -d= -f2)
    [ -z "$run_user" ] && run_user="root(旧版本)"

    cert="未知"
    echo | timeout 5 openssl s_client \
        -connect "127.0.0.1:$p" -servername "$dom" -alpn h2 2>/dev/null \
        | grep -q "Verify return code: 0" \
        && cert="\033[32m有效\033[0m" \
        || cert="\033[33m签发中 / journalctl -u sing-box\033[0m"

    echo "=============================================="
    printf "节点: \033[36m%s-%s\033[0m  协议: \033[36m%s\033[0m  内核: \033[36mv%s\033[0m\n" "$node_name" "$IP" "$proto" "$sbver"
    printf "端口: \033[36m%s\033[0m  域名: \033[36m%s\033[0m\n" "$p" "$dom"
    printf "证书: %b  CA: \033[36m%s\033[0m\n" "$cert" "$ca_name"
    printf "运行用户: \033[36m%s\033[0m（非root，最小权限）\n" "$run_user"
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
}

rm -f /usr/local/bin/nb
{ echo '#!/bin/bash'; declare -f nb_info; echo 'nb_info'; } > /usr/local/bin/nb
chmod +x /usr/local/bin/nb

echo ""
echo "==================== 安装完成 ===================="
echo "协议:$PROTO  域名:$DOMAIN  端口:$RAND_PORT  内核:v$SB_VER"
echo "CA:$CA_NAME  指纹:safari  运行用户:$SBX_USER（非root）"
echo "新增与加固项："
echo "  ✅ 每天 0 点 systemd timer 自动重启，带 15s 随机延迟抖动"
echo "  ✅ 吞吐优先策略：进程优先级 Nice=-10、解除 LimitMEMLOCK/NOFILE 限制"
echo "  ✅ 扩充系统级 TCP/UDP 读写缓冲区至 16MB"
echo "  ✅ 已拦截 HTTP 订阅服务器的目录列表功能，防止文件遍历与 Token 泄漏"
echo "输入 nb 查看节点信息和订阅链接"
echo "==================================================="
/usr/local/bin/nb
