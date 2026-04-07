cat << 'EOF' > /root/tk.sh
#!/bin/bash
set -e

# --- 1. 环境初始化 ---
echo "正在准备安装环境..."
apt update -y && apt install -y curl openssl chrony tar wget grep

# --- 2. 借用“高手”的内核版本获取与路径逻辑 ---
cpu=$(uname -m)
[ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"

# 动态获取最新版本号
sbcore=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
[ -z "$sbcore" ] && sbcore="1.10.7" # 兜底版本

sbname="sing-box-$sbcore-linux-$cpu"
mkdir -p /etc/s-box

# --- 3. 借用“高手”的专业下载逻辑 (带重试与校验) ---
echo "正在下载 Sing-box v$sbcore..."
# 使用镜像站加速，同时保留高手的 --retry 参数
curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 "https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"

# 校验下载是否成功 (高手逻辑第一层)
if [[ -f '/etc/s-box/sing-box.tar.gz' ]]; then
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/$sbname/sing-box /etc/s-box/sing-box
    rm -rf /etc/s-box/{sing-box.tar.gz,$sbname}
    
    # 校验解压是否成功 (高手逻辑第二层)
    if [[ -f '/etc/s-box/sing-box' ]]; then
        chown root:root /etc/s-box/sing-box
        chmod +x /etc/s-box/sing-box
        echo "成功安装内核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"
    else
        echo -e "\033[31m错误：下载内核不完整，安装失败！\033[0m" && exit 1
    fi
else
    echo -e "\033[31m错误：下载内核失败，请检查网络！\033[0m" && exit 1
fi

# --- 4. TikTok 内核参数优化 ---
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
sysctl --system >/dev/null 2>&1

# --- 5. 生成配置与 REALITY 密钥 ---
# 这里一定要用刚装好的内核来生成密钥，确保公钥不为空
KEY_PAIR=$(/etc/s-box/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)
IP=$(curl -s4m5 icanhazip.com)

cat > /etc/s-box/config.json <<JSON
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

# --- 6. 启动服务 ---
cat > /etc/systemd/system/sing-box.service <<S_EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
S_EOF

systemctl daemon-reload
systemctl enable --now sing-box

# --- 7. 输出结果 ---
echo -e "\n\033[32mTikTok 矩阵节点全自动部署成功！\033[0m"
echo "--------------------------------------------------"
echo "VLESS 链接 (直接导入手机):"
echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$PUBLIC_KEY&sid=$SHORT_ID#TK-$IP"
echo "--------------------------------------------------"
EOF

bash /root/tk.sh
