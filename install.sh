#!/bin/bash
set -e

# ==============================
# TikTok 一键部署 - 终极无警告版
# ==============================

apt update -y
apt install -y curl openssl chrony needrestart

mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-autorestart.conf

sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

timedatectl set-timezone UTC

# 修复：使用正确服务名，无警告
systemctl enable --now chrony

cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_max_syn_backlog=8192
vm.swappiness=10
EOF
sysctl -p

# 安装 sing-box
curl -Ls https://sing-box.sagernet.org/install.sh | bash -s -- --latest

# 你写的完美密钥生成
echo "正在本地生成 REALITY 密钥..."
KEY_PAIR=$(sing-box generate reality-keypair)

PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "\033[31m错误：密钥生成失败！\033[0m"
    exit 1
fi
echo "密钥生成成功：私钥与公钥已匹配 ✅"

SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=443
SNI="www.apple.com"

# 配置
cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "0.0.0.0",
    "listen_port": 443,
    "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$SNI",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$SNI", "server_port": 443},
        "private_key": "$PRIVATE_KEY",
        "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

systemctl daemon-reload
systemctl enable --now sing-box

IP=$(curl -s --ipv4 ifconfig.me)

echo -e "\n\033[32m##################################################"
echo -e "###       TikTok 矩阵专用配置 (Nikki/VLESS)     ###"
echo "##################################################\033[0m"

echo "--- 1. 手机 Nikki YAML 格式 ---"
echo "- name: \"TK-iPhone-$(echo $IP | cut -d. -f4)\"
  type: vless
  server: $IP
  port: $PORT
  uuid: $UUID
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $SNI
  reality-opts:
    public-key: $PUBLIC_KEY
    short-id: $SHORT_ID
  client-fingerprint: safari"

echo -e "\n--- 2. VLESS 链接 ---"
echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
