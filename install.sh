#!/bin/bash
set -e

# ==============================================
# TikTok 终极抗风控 · 镜像加速版 (V3.0)
# 特点：绕过 GitHub 拦截、CDN 加速下载、强制重置环境
# ==============================================

# 1. 环境初始化
apt update -y && apt install -y curl openssl chrony needrestart tar

# 2. 彻底清理 sysctl 乱象 (防止之前刷屏重复)
cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
cat > /etc/sysctl.d/99-tiktok.conf <<EOF
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
sysctl --system

# 3. 下载 sing-box (使用镜像加速，绕过 GitHub 拦截)
echo "正在通过加速通道下载 sing-box..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then PLATFORM="amd64"; else PLATFORM="arm64"; fi

# 这里换成了镜像站链接，专门对付机房 IP 被 GitHub 拦截的问题
DOWNLOAD_URL="https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v1.8.10/sing-box-1.8.10-linux-$PLATFORM.tar.gz"

curl -Lo /tmp/sb.tar.gz "$DOWNLOAD_URL"

# 检查文件是否真的是 HTML (如果是 HTML 说明又被拦截了)
if grep -q "<!doctype html>" /tmp/sb.tar.gz; then
    echo -e "\033[31m警告：下载链接仍被 GitHub 拦截！尝试备用方案...\033[0m"
    # 备用方案：直接从我们指定的快速节点下载
    curl -Lo /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.8.10/sing-box-1.8.10-linux-$PLATFORM.tar.gz"
fi

tar -xzf /tmp/sb.tar.gz -C /tmp
mv /tmp/sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

# 4. 生成配置与密钥
KEY_PAIR=$(/usr/local/bin/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')
SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)
IP=$(curl -s --ipv4 ifconfig.me)

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

# 5. 启动服务
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

# 6. 输出结果
echo -e "\n\033[32m配置生成成功！\033[0m"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
