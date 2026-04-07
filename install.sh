cat > /tmp/tk.sh <<'EOF'
#!/bin/bash
set -e

# 基础依赖
apt update -y
apt install -y curl openssl chrony needrestart wget

# 关闭弹窗
mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-autorestart.conf

# 关闭 IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

# 时间同步
timedatectl set-timezone UTC
systemctl restart chrony
systemctl enable chrony

# TCP 优化
cat >> /etc/sysctl.conf <<CONF
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
CONF
sysctl -p

# ==============================
# 修复 404 错误！直接下载二进制
# ==============================
wget -O /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.8.10/sing-box-1.8.10-linux-amd64.tar.gz
tar -xzf /tmp/sing-box.tar.gz -C /tmp
cp /tmp/sing-box-1.8.10-linux-amd64/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 你的完美密钥生成
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

# 配置文件
cat > /etc/sing-box/config.json <<JSON
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
JSON

# 开机自启
cat > /etc/systemd/system/sing-box.service <<SERVICE
[Unit]
Description=sing-box
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now sing-box

IP=$(curl -s --ipv4 ifconfig.me)

echo -e "\n\033[32m##################################################"
echo -e "###       TikTok 矩阵专用配置 (Nikki/VLESS)     ###"
echo "##################################################\033[0m"

echo "--- 1. 手机 Nikki YAML 格式 ---"
echo "- name: \"TK-iPhone-$IP\"
  type: vless
  server: $IP
  port: 443
  uuid: $UUID
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: www.apple.com
  reality-opts:
    public-key: $PUBLIC_KEY
    short-id: $SHORT_ID
  client-fingerprint: safari"

echo -e "\n--- 2. VLESS 链接 ---"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
EOF

chmod +x /tmp/tk.sh
bash /tmp/tk.sh
