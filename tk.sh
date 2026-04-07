#!/bin/bash
# =========================================================
# TikTok 矩阵专用部署脚本 (V14.0 动态随机指纹版)
# 特性：自动随机伪装域名、随机 ShortID、内核丢包优化
# =========================================================
set -e

# --- 0. 强制静默模式 ---
export DEBIAN_FRONTEND=noninteractive
echo 'needrestart { restart: "a" }' > /etc/needrestart/conf.d/99-force-restart.conf 2>/dev/null || true

# --- 1. 环境准备 ---
apt update -y && apt install jq socat curl wget openssl tar grep chrony -y
ufw disable >/dev/null 2>&1 || true
iptables -P INPUT ACCEPT && iptables -F

# --- 2. 优化配置 (包含 MTU 探测对抗丢包) ---
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
timedatectl set-timezone UTC
systemctl restart chrony

sed -i '/net./d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<CONF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
CONF
sysctl -p >/dev/null 2>&1

# --- 3. 架构检测与安装 ---
cpu=$(uname -m)
[ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"
sbcore='1.10.7'
sbname="sing-box-$sbcore-linux-$cpu"
mkdir -p /etc/s-box

echo "正在安装 Sing-box v$sbcore..."
curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 5 "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
mv /etc/s-box/$sbname/sing-box /etc/s-box/sing-box
rm -rf /etc/s-box/{sing-box.tar.gz,$sbname}
chmod +x /etc/s-box/sing-box

# --- 4. 核心随机化逻辑 (V14.0 新增) ---
# 随机域名池：包含微软、三星、英伟达等大厂，避开单一 apple.com 被连坐
domains=("www.microsoft.com" "www.itunes.apple.com" "www.samsung.com" "www.nvidia.com" "www.cloudflare.com" "www.speedtest.net" "www.yahoo.com" "www.amd.com")
RAND_DOMAIN=${domains[$RANDOM % ${#domains[@]}]}

# 随机 ShortID 和 UUID
short_id=$(/etc/s-box/sing-box generate rand --hex 4)
uuid=$(/etc/s-box/sing-box generate uuid)

# 密钥生成
/etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
private_key=$(grep -i "private" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
public_key=$(grep -i "public" /tmp/sb_keys.txt | awk -F': ' '{print $2}' | tr -d '[:space:]')
rm -f /tmp/sb_keys.txt

IP=$(curl -s4m5 icanhazip.com)

# --- 5. 写配置文件 (使用随机变量) ---
cat > /etc/s-box/sb.json <<JSON
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": 443,
    "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$RAND_DOMAIN",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$RAND_DOMAIN", "server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
JSON

# --- 6. 启服务 ---
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box

# --- 7. 最终成果展示 ---
clear
echo "======================================================"
echo "🚀 TikTok 矩阵动态随机版 (V14.0) 部署成功！"
echo "======================================================"
echo -e "\033[32m当前随机伪装域名: $RAND_DOMAIN\033[0m"
echo -e "\033[32m当前随机 ShortID: $short_id\033[0m"
echo "------------------------------------------------------"
echo -e "\033[33m1. VLESS 分享链接 (Shadowrocket):\033[0m"
echo "vless://$uuid@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$RAND_DOMAIN&fp=safari&pbk=$public_key&sid=$short_id#TK-$RAND_DOMAIN-$IP"

echo -e "\n\033[33m2. Nikki / Clash 配置:\033[0m"
echo "  - name: \"TK-$IP\""
echo "    type: vless"
echo "    server: $IP"
echo "    port: 443"
echo "    uuid: $uuid"
echo "    udp: true"
echo "    tls: true"
echo "    flow: xtls-rprx-vision"
echo "    servername: $RAND_DOMAIN"
echo "    reality-opts:"
echo "      public-key: $public_key"
echo "      short-id: $short_id"
echo "    client-fingerprint: safari"
echo "======================================================"
