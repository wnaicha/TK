cat << 'EOF' > /root/tk.sh
#!/bin/bash
set -e

# 1. 基础依赖
apt update -y
apt install -y curl openssl chrony needrestart gnupg2

# 2. 彻底清理之前的 sysctl 乱象
cat > /etc/sysctl.conf <<CONF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
CONF

cat > /etc/sysctl.d/99-tiktok.conf <<CONF
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
sysctl --system

# 3. 换一种更稳的方式安装 sing-box (不走 github 脚本)
curl -fsSL https://sing-box.sagernet.org/gpg.key | gpg --dearmor -o /etc/apt/keyrings/sagernet.gpg
echo "deb [signed-by=/etc/apt/keyrings/sagernet.gpg] https://deb.sagernet.org/ nodes main" > /etc/apt/sources.list.d/sagernet.list
apt update
apt install sing-box -y

# 4. 生成密钥
echo "正在本地生成 REALITY 密钥..."
KEY_PAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')

SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)
IP=$(curl -s --ipv4 ifconfig.me)

# 5. 写入配置
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
      "server_name": "www.apple.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "www.apple.com", "server_port": 443},
        "private_key": "$PRIVATE_KEY",
        "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
JSON

systemctl daemon-reload
systemctl enable --now sing-box

echo -e "\n\033[32m配置生成成功！\033[0m"
echo "--- 手机 Nikki YAML ---"
echo "- name: \"TK-iPhone-$(echo $IP | cut -d. -f4)\"
  type: vless
  server: $IP
  port: 443
  uuid: $UUID
  tls: true
  flow: xtls-rprx-vision
  servername: www.apple.com
  reality-opts: { public-key: $PUBLIC_KEY, short-id: $SHORT_ID }
  client-fingerprint: safari"
echo -e "\n--- VLESS 链接 ---"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
EOF

bash /root/tk.sh
