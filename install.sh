#!/bin/bash

# ==============================================
# TikTok 终极抗风控·全自动无弹窗批量部署版
# 无交互 · 防空Key · 不卡机 · 高稳定
# ==============================================

# 0. 永久关闭 needrestart 弹窗（永不卡住）
apt update && apt install -y curl openssl chrony needrestart
mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-autorestart.conf

# 1. 关闭 IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

# 2. 时间同步
timedatectl set-timezone UTC
systemctl restart chronyd

# 3. TCP 抗风控优化
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

# 4. 生成 REALITY 密钥（自动重试3次）
echo "正在生成 REALITY 密钥..."
for i in {1..3}; do
    KEYS=$(curl -sL --connect-timeout 10 --max-time 30 \
        https://github.com/SagerNet/sing-box/releases/download/v1.8.10/sing-box-1.8.10-linux-amd64.tar.gz \
        | tar -xzO */sing-box generate reality-keypair 2>/dev/null)
    
    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}')
    
    if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ]; then
        echo "密钥生成成功 ✅"
        break
    else
        echo "第 $i 次失败，重试中..."
        sleep 2
    fi
done

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "\033[31m错误：网络异常，密钥生成失败！\033[0m"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=443
SNI="www.apple.com"

# 5. 官方静默安装 sing-box（无交互）
bash <(curl -Ls https://sing-box.sagernet.org/install.sh) --latest

# 6. 写入配置
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
systemctl restart sing-box
systemctl enable sing-box

# 7. 输出配置
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
