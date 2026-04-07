#!/bin/bash
set -e

# ==============================================
# TikTok 终极抗风控 · 100台矩阵批量部署版 (V2.0)
# 特点：二进制安装、跳过apt源、内核彻底清理、无交互
# ==============================================

# 1. 基础依赖环境
apt update -y
apt install -y curl openssl chrony needrestart tar

# 2. 彻底清理并重置系统内核参数 (解决重复写入问题)
cat > /etc/sysctl.conf <<CONF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
CONF

# 写入专门的 TikTok 优化配置文件
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

# 3. 二进制方式安装 sing-box (不依赖官方apt源，避开404)
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then PLATFORM="amd64"; else PLATFORM="arm64"; fi

curl -Lo /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.8.10/sing-box-1.8.10-linux-$PLATFORM.tar.gz
tar -xzf /tmp/sb.tar.gz -C /tmp
mv /tmp/sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

# 4. 生成 REALITY 密钥对
KEY_PAIR=$(/usr/local/bin/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')

SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)
IP=$(curl -s --ipv4 ifconfig.me)

# 5. 写入配置文件
mkdir -p /etc/sing-box
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

# 6. 配置 Systemd 服务启动
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 7. 最终输出结果
echo -e "\n\033[32mTikTok 节点部署完成！✅\033[0m"
echo "--------------------------------------------------"
echo "1. Nikki YAML 格式:"
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
echo "--------------------------------------------------"
echo "2. 通用 VLESS 链接:"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
