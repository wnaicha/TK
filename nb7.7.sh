#!/bin/bash
set -e

# ===============================================================
# TikTok 矩阵环境 - VLESS/Trojan + TLS + 多CA自适应版 V10.0
#  - 破局 429 限流：支持自选 Let's Encrypt / ZeroSSL / Buypass 证书链
#  - 敏感值优先读环境变量，全线参数完美持久化
#  - 完美联动：物理屏蔽 UDP 防 WebRTC 泄露，同步输出规范化 Provider 订阅
# 适配 sing-box 1.13.13 | 仅支持 Debian / Ubuntu
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

# --- 1. 内核加速 BBR/FQ ---
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

# --- 2. 创建目录 ---
mkdir -p /etc/s-box /etc/s-box/acme

# --- 3. 彻底释放旧服务 ---
systemctl stop sing-box sb-sub nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
systemctl daemon-reload
sleep 1

# ================================================================
# 工具函数
# ================================================================
read_val() {
    local _outvar="$1" _prompt="$2" _file="$3" _envvar="$4" _default="$5"
    local _val _old
    _old=$(cat "$_file" 2>/dev/null || echo "")
    if [ -n "${!_envvar}" ]; then
        _val="${!_envvar}"
        echo "   ✅ $_envvar = $_val（环境变量）"
    elif [ -n "$_old" ]; then
        read -r -p "   $_prompt (旧值:$_old，回车保留): " _input
        _val="${_input:-$_old}"
    else
        read -r -p "   $_prompt (${_default:+回车默认$_default}): " _input
        _val="${_input:-$_default}"
    fi
    [ -z "$_val" ] && { echo "❌ $_prompt 不能为空"; exit 1; }
    mkdir -p "$(dirname "$_file")"
    echo "$_val" > "$_file"
    eval "$_outvar='$_val'"
}

read_secret() {
    local _outvar="$1" _prompt="$2" _envvar="$3" _val
    if [ -n "${!_envvar}" ]; then
        _val="${!_envvar}"
        echo "   ✅ $_envvar（环境变量传入，已读取）"
    else
        read -r -s -p "   $_prompt（数据不显形）: " _val; echo ""
        [ -z "$_val" ] && { echo "❌ $_prompt 不能为空"; exit 1; }
    fi
    eval "$_outvar='$_val'"
}

# ================================================================
# 配置收集
# ================================================================
echo ""
echo "========================================================"
echo " TikTok 矩阵环境 VLESS/Trojan 终极多 CA 自适应版 V10.0"
echo "========================================================"

echo ""
echo "▸ 1. 敏感凭据安全接入"
read_secret SUB_SALT   "SUB_SALT 订阅特征盐值" "SUB_SALT"
read_secret CF_TOKEN   "Cloudflare API Token"  "CF_TOKEN"
read_secret CF_ZONE_ID "Cloudflare Zone ID"   "CF_ZONE_ID"

echo ""
echo "▸ 2. 核心协议选择"
OLD_PROTO=$(cat /etc/s-box/protocol 2>/dev/null || echo "")
if [ -n "$OLD_PROTO" ]; then
    read -r -p "   选择协议 [1]VLESS+Vision [2]Trojan (上次: $OLD_PROTO，回车保留): " _p
else
    read -r -p "   选择协议 [1]VLESS+Vision [2]Trojan (回车默认 1-VLESS): " _p
fi
case "$_p" in
    1) PROTO="vless" ;;
    2) PROTO="trojan" ;;
    "") PROTO="${OLD_PROTO:-vless}" ;;
    vless|trojan) PROTO="$_p" ;;
    *) echo "❌ 输入错误，只能选 1 或 2"; exit 1 ;;
esac
echo "$PROTO" > /etc/s-box/protocol
echo "   ✅ 当前协议设定为: $PROTO"

echo ""
echo "▸ 3. 节点网络参数"
read_val NODE_NAME "输入节点名称"     /etc/s-box/node_name  "NODE_NAME" "TK-matrix"
read_val DOMAIN    "输入完整解析域名" /etc/s-box/domain     "DOMAIN"    ""
read_val RAND_PORT "自定义代理监听端口" /etc/s-box/listen_port "PORT"      "443"

# 固定的高通透率 ACME 公共通知邮箱，防 Let's Encrypt 恶意限流
ACME_EMAIL="tiktokmatrix.ca@gmail.com"
echo "$ACME_EMAIL" > /etc/s-box/acme_email

echo ""
echo "▸ 4. 【核心升级】自选证书签发机构 (破局 429 限流关键)"
OLD_CA=$(cat /etc/s-box/acme_server_idx 2>/dev/null || echo "1")
echo "   [1] Let's Encrypt (默认 / 有极严格的周重复申请 429 限流)"
echo "   [2] ZeroSSL (推荐 / 额度独立 / 申请极速)"
echo "   [3] Buypass (挪威老牌 CA / 稳定通透 / 额度宽松)"
read -r -p "   请选择证书服务商 [1-3] (上次: $OLD_CA, 回车保留): " CA_CHOICE
CA_CHOICE="${CA_CHOICE:-$OLD_CA}"
echo "$CA_CHOICE" > /etc/s-box/acme_server_idx

case "$CA_CHOICE" in
    2)
        CA_SERVER="https://acme.zerossl.com/v2/DV90"
        echo "   ✅ 已切换至证书源: ZeroSSL"
        ;;
    3)
        CA_SERVER="https://api.buypass.com/acme/directory"
        echo "   ✅ 已切换至证书源: Buypass"
        ;;
    *)
        CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
        echo "   ✅ 已切换至证书源: Let's Encrypt"
        ;;
esac

# 端口碰撞验证
case "$RAND_PORT" in ''|*[!0-9]*) echo "❌ 端口必须是纯数字"; exit 1 ;; esac
{ [ "$RAND_PORT" -lt 1 ] || [ "$RAND_PORT" -gt 65535 ]; } && { echo "❌ 端口超出1-65535范围"; exit 1; }
[ "$RAND_PORT" = "$SUB_PORT" ] && { echo "❌ 端口与订阅端口($SUB_PORT)冲突！"; exit 1; }

# ================================================================
# 网络与公网 IP 嗅探
# ================================================================
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null \
  || curl -s4m5 https://icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')
IP=$(echo "$IP" | tr -d '[:space:]')
[ -z "$IP" ] && { echo "❌ 无法获取本机公网 IP，请检查物理网络"; exit 1; }
echo "$IP" > /etc/s-box/server_ip

echo ""
echo "📡 本地集群拓扑 -> 节点: $NODE_NAME | IP: $IP | 端口: $RAND_PORT"

# ================================================================
# Cloudflare DNS 自动化解析集群打通
# ================================================================
echo ""
echo "🌐 正在下发 Cloudflare 骨干网 A 记录解析: $DOMAIN → $IP"

_cf() {
    curl -s -X "$1" "https://api.cloudflare.com/client/v4${2}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        ${3:+--data "$3"}
}

_chk=$(_cf GET "/zones/${CF_ZONE_ID}")
if ! echo "$_chk" | jq -e '.success==true' >/dev/null 2>&1; then
    echo "❌ Cloudflare 凭据验证失败，请检查 TOKEN 或 ZONE_ID 是否输入有误！"
    exit 1
fi

_pl="{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}"
_list=$(_cf GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}")
_rid=$(echo "$_list" | jq -r '.result[0].id // empty')
_oip=$(echo "$_list" | jq -r '.result[0].content // empty')

if [ -n "$_rid" ]; then
    if [ "$_oip" = "$IP" ]; then
        echo "   ✅ DNS 记录一致，无需重复覆写"
    else
        _r=$(_cf PUT "/zones/${CF_ZONE_ID}/dns_records/${_rid}" "$_pl")
        echo "   ✅ 已成功更新解析: $_oip → $IP"
    fi
else
    _r=$(_cf POST "/zones/${CF_ZONE_ID}/dns_records" "$_pl")
    echo "   ✅ 已成功创建 A 记录: $DOMAIN → $IP"
fi

# 核心资产防污染：立即擦除敏感变量，绝不落盘
unset CF_TOKEN CF_ZONE_ID _cf _chk _pl _list _rid _oip _r

# 域名就地解析强同步探测
echo "⏳ 正在同步全网 DNS 缓存（最多等待 90 秒）..."
for _i in $(seq 1 18); do
    sleep 5
    _res=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    [ "$_res" = "$IP" ] && { echo "   ✅ 全网 DNS 解析已同步就位！"; break; }
    printf "   [+] 等待中.. 已耗时 %ds.. 当前本地解析为: %s\n" "$((_i*5))" "${_res:-未生效}"
done

# ================================================================
# 物理隔离与防火墙策略
# ================================================================
iptables -I INPUT -p tcp --dport "$RAND_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80            -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport $SUB_PORT     -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
ufw disable >/dev/null 2>&1 || true

# 【修复】移除了对 80 端口的占用检查，只验证自定义代理端口，防止二次重装时因旧服务监听引发冲突
if ss -tlnp 2>/dev/null | grep -q ":$RAND_PORT "; then
    echo "❌ 端口 $RAND_PORT 已被其他应用锁定，请更换端口再试"; exit 1
fi

# 离散 Token 异步哈希运算
SUB_TOKEN=$(echo -n "${NODE_NAME}-${PROTO}-${IP}-${SUB_SALT}" | sha256sum | awk '{print $1}')
unset SUB_SALT
echo "$SUB_TOKEN" > /etc/s-box/sub_token
mkdir -p "${SUB_YAML_ROOT}/${SUB_TOKEN}"

# ================================================================
# sing-box 核心组件下载与架构校验
# ================================================================
INSTALLED_VER=$(/etc/s-box/sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
if [ "$INSTALLED_VER" != "$SB_VER" ]; then
    echo "📦 正在下发原厂 sing-box v$SB_VER 二进制内核..."
    wget -q -O /etc/s-box/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/sing-box-*/sing-box /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/sing-box-*-linux-*
else
    echo "   ✅ sing-box v$SB_VER 核心完好，跳过下载"
fi

# ================================================================
# 资产特征存储与还原处理
# ================================================================
if [ "$PROTO" = "vless" ]; then
    if [ -f /etc/s-box/uuid ]; then
        uuid=$(cat /etc/s-box/uuid)
        echo "   ✅ 成功还原已有 UUID 特征"
    else
        uuid=$(/etc/s-box/sing-box generate uuid)
        echo "$uuid" > /etc/s-box/uuid
    fi
else
    if [ -f /etc/s-box/trojan_pass ]; then
        tpass=$(cat /etc/s-box/trojan_pass)
        echo "   ✅ 成功还原已有 Trojan 密钥"
    else
        tpass=$(/etc/s-box/sing-box generate rand --hex 16)
        echo "$tpass" > /etc/s-box/trojan_pass
    fi
fi

# ================================================================
# 构建服务端动态 JSON（引入自适应多 CA server 分发）
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
      "enabled": true, "server_name": "$DOMAIN",
      "acme": { 
        "server": "$CA_SERVER",
        "domain": ["$DOMAIN"], 
        "email": "$ACME_EMAIL", 
        "data_directory": "/etc/s-box/acme" 
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "rules": [{ "network": "udp", "action": "reject" }], "final": "direct" }
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
      "enabled": true, "server_name": "$DOMAIN",
      "acme": { 
        "server": "$CA_SERVER",
        "domain": ["$DOMAIN"], 
        "email": "$ACME_EMAIL", 
        "data_directory": "/etc/s-box/acme" 
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "rules": [{ "network": "udp", "action": "reject" }], "final": "direct" }
}
JSON
fi

/etc/s-box/sing-box check -c "$CONF_PATH" || { echo "❌ 配置校验发生内部错误"; exit 1; }

# ================================================================
# 托管 Systemd 服务常驻
# ================================================================
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Matrix TLS Service
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
Description=sing-box Matrix Subscription Server
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

echo "⏳ 正在向选定的 CA 机构申请下发合规证书（预计耗时 10-25 秒）..."
sleep 12
systemctl restart sb-sub

# ================================================================
# 【修复】同步输出纯净的、无 proxies 顶层标签的标准 Provider 订阅文件
# ================================================================
_token=$(cat /etc/s-box/sub_token)
_port=$(cat /etc/s-box/listen_port)
if [ "$PROTO" = "vless" ]; then
cat > "${SUB_YAML_ROOT}/${_token}/proxy.yaml" <<YAML
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
- name: "$NODE_NAME-$IP"
  type: trojan
  server: $IP
  port: $_port
  password: $tpass
  network: tcp
  udp: false
  sni: $DOMAIN
  client-fingerprint: safari
YAML
fi

# ================================================================
# 集成 nb 控制台管理快捷命令
# ================================================================
nb_info() {
    clear
    CP="/etc/s-box/sb.json"
    IP=$(cat /etc/s-box/server_ip 2>/dev/null || echo "<服务器IP>")
    proto=$(cat /etc/s-box/protocol 2>/dev/null || echo "vless")
    dom=$(jq -r '.inbounds[0].tls.server_name' "$CP")
    p=$(jq -r '.inbounds[0].listen_port' "$CP")
    node_name=$(cat /etc/s-box/node_name)
    sub_token=$(cat /etc/s-box/sub_token)
    SUB_LINK="http://$IP:8080/$sub_token/proxy.yaml"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    bbr=$(lsmod | grep -q bbr && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m")
    
    cert="未知"
    echo | timeout 5 openssl s_client -connect "127.0.0.1:$p" -servername "$dom" 2>/dev/null \
        | grep -q "Verify return code: 0" \
        && cert="\033[32m 运行中 (安全合规) \033[0m" \
        || cert="\033[33m 签发中 (如长久卡死请换 CA 重装或查看: journalctl -u sing-box) \033[0m"

    echo "=========================================================="
    printf "集群节点: \033[36m%s-%s\033[0m   安全协议: \033[36m%s\033[0m\n" "$node_name" "$IP" "$proto"
    printf "入站端口: \033[36m%s\033[0m   自备域名: \033[36m%s\033[0m\n" "$p" "$dom"
    printf "物理证书: %b   BBR加速: %b   队列: \033[32m%s\033[0m\n" "$cert" "$bbr" "$qdisc"
    echo "=========================================================="
    echo "📋 路由器集群 Provider 分流参数"
    echo "=========================================================="

    if [ "$proto" = "vless" ]; then
        u=$(jq -r '.inbounds[0].users[0].uuid' "$CP")
        link="vless://$u@$IP:$p?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$dom&fp=safari&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: vless\n    server: %s\n    port: %s\n" "$node_name" "$IP" "$IP" "$p"
        printf "    uuid: %s\n    network: tcp\n    udp: false\n    tls: true\n" "$u"
        printf "    servername: %s\n    flow: xtls-rprx-vision\n    client-fingerprint: safari\n" "$dom"
    else
        tp=$(jq -r '.inbounds[0].users[0].password' "$CP")
        link="trojan://$tp@$IP:$p?security=tls&sni=$dom&fp=safari&type=tcp#$node_name-$IP"
        printf "  - name: \"%s-%s\"\n    type: trojan\n    server: %s\n    port: %s\n" "$node_name" "$IP" "$IP" "$p"
        printf "    password: %s\n    network: tcp\n    udp: false\n" "$tp"
        printf "    sni: %s\n    client-fingerprint: safari\n" "$dom"
    fi

    echo "----------------------------------------------------------"
    echo "🔗 独享原生分享链接"
    echo -e "\033[32m$link\033[0m"
    qrencode -t ansiutf8 "$link"
    echo "=========================================================="
    echo "📡 软路由高并发订阅分发源 (Clash / Nikki Provider 专属)"
    echo "=========================================================="
    echo -e "\033[33m$SUB_LINK\033[0m"
    echo "=========================================================="
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
}

rm -f /usr/local/bin/nb
{ echo '#!/bin/bash'; declare -f nb_info; echo 'nb_info'; } > /usr/local/bin/nb
chmod +x /usr/local/bin/nb

echo ""
echo "======================= 安装引导完毕 ======================="
echo " 物理证书申请指令已提交。系统将在后台建立安全审计隧道。"
echo " 稍后可在终端直接键入快捷命令：nb  查看实时链路质量与订阅。"
echo "============================================================="
/usr/local/bin/nb
