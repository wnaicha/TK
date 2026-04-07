#!/bin/bash
# =========================================================
# TikTok 矩阵专用部署脚本 (内核优化版)
# 特点：复刻勇哥下载逻辑 + 强制时间同步 + 内核抗风控调优
# =========================================================
set -e

# --- 1. 环境依赖与防火墙全开 ---
apt update -y && apt install jq socat curl wget openssl tar grep chrony -y
ufw disable >/dev/null 2>&1 || true
iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F

# --- 2. 禁用 IPv6 ---
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

# --- 3. 时间同步 (UTC) ---
timedatectl set-timezone UTC
systemctl restart chrony
systemctl enable chrony >/dev/null 2>&1

# --- 4. TCP 内核抗风控调优 (去重写入模式) ---
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

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
sysctl -p >/dev/null 2>&1

# --- 5. Sing-box 下载逻辑 ---
cpu=$(uname -m)
case "$cpu" in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) exit 1;;
esac

sbcore='1.10.7'
sbname="sing-box-$sbcore-linux-$cpu"
mkdir -p /etc/s-box

echo "正在下载 Sing-box v$sbcore..."
curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz

if [[ -f '/etc/s-box/sing-box.tar.gz' ]]; then
    if grep -q "<!doctype html>" /etc/s-box/sing-box.tar.gz; then
        echo -e "\033[33mGH 代理失效，切换官方地址...\033[0m"
        curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz
    fi

    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/$sbname/sing-box /etc/s-box/sing-box
    rm -rf /etc/s-box/{sing-box.tar.gz,$sbname}
    chown root:root /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box

    sbnh=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}' | cut -d '.' -f 1,2)
    echo -e "\033[32mSing-box 安装成功 | 版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}') | 主版本：$sbnh\033[0m"
else
    echo "下载失败，请检查网络！" && exit 1
fi

# --- 6. 密钥生成与提取（已修复）---
key_pair=$(/etc/s-box/sing-box generate reality-keypair)
private_key=$(echo "$key_pair" | grep 'Private key:' | awk '{print $3}')
public_key=$(echo "$key_pair" | grep 'Public key:' | awk '{print $3}')
short_id=$(/etc/s-box/sing-box generate rand --hex 4)
uuid=$(/etc/s-box/sing-box generate uuid)
IP=$(curl -s4m5 icanhazip.com)

# --- 7. 写入配置文件 ---
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
      "server_name": "www.apple.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "www.apple.com", "server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
JSON

# --- 8. 服务配置与启动 ---
cat > /etc/systemd/system/sing-box.service <<S_EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
S_EOF

systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box

# --- 9. 【直接输出 Clash 完整配置】---
echo -e "\n\033[32m===============================================\033[0m"
echo -e "\033[32m✅ Clash 完整配置（直接复制使用）\033[0m"
echo -e "\033[32m===============================================\033[0m"

cat <<EOF
- name: "TK-$IP"
  type: vless
  server: $IP
  port: 443
  uuid: $uuid
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: www.apple.com
  reality-opts:
    public-key: $public_key
    short-id: $short_id
  client-fingerprint: chrome
EOF

echo -e "\n\033[32m===============================================\033[0m"
