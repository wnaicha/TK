#!/bin/bash
set -e

# ==============================================
# TikTok 终极抗风控 · 镜像加速版 (V3.0)
# 整合：自动版本 / 多架构 / 自动提取 sbnh 版本号
# ==============================================

# ================= 核心变量（可自行修改）=================
sbcore="1.8.10"             # 版本号
sbname="sing-box-$sbcore-linux"
sbpath="/usr/local/bin"
# ========================================================

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

# 3. 自动识别架构
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  PLATFORM="amd64"
else
  PLATFORM="arm64"
fi
sbfile="${sbname}-${PLATFORM}"
DOWNLOAD_URL="https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbfile}.tar.gz"

# 4. 下载 + 安装 sing-box（整合你要的逻辑）
echo "正在下载 sing-box v$sbcore ($PLATFORM)..."
curl -L -o /tmp/sing-box.tar.gz -# --retry 2 "$DOWNLOAD_URL"

if [[ -f '/tmp/sing-box.tar.gz' ]]; then
  # 检测是否下载成HTML错误页
  if grep -q "<!doctype html>" /tmp/sing-box.tar.gz; then
    echo -e "\033[33mGH代理失效，切换官方直连...\033[0m"
    curl -L -o /tmp/sing-box.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbfile}.tar.gz"
  fi

  # 解压安装
  tar xzf /tmp/sing-box.tar.gz -C /tmp
  mv /tmp/${sbfile}/sing-box $sbpath/
  chown root:root $sbpath/sing-box
  chmod +x $sbpath/sing-box
  rm -rf /tmp/sing-box.tar.gz /tmp/${sbfile}

  # 自动提取主版本号 sbnh
  sbnh=$($sbpath/sing-box version 2>/dev/null | awk '/version/{print $NF}' | cut -d '.' -f 1,2)
  echo -e "\033[32mSing-box 安装成功 | 版本：$($sbpath/sing-box version | awk '/version/{print $NF}') | 主版本：$sbnh\033[0m"
else
  echo -e "\033[31m下载失败！\033[0m"
  exit 1
fi

# 5. 生成配置与密钥
KEY_PAIR=$($sbpath/sing-box generate reality-keypair)
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

# 6. 注册系统服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$sbpath/sing-box run -c /etc/sing-box/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 7. 输出节点信息
echo -e "\n\033[32m======== TikTok 抗风控节点生成成功 ========\033[0m"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
echo -e "\033[32m===========================================\033[0m"
