#!/bin/bash
# =========================================================
# TikTok 矩阵专用部署脚本 (V10.0 终极全能版)
# 特点：修复横杠私钥抓取、强制 Safari 指纹、Clash 格式精准缩进
# =========================================================
set -e

# --- 0. 自动化环境准备 ---
export DEBIAN_FRONTEND=noninteractive
if [ -d /etc/needrestart/conf.d/ ]; then
    echo 'needrestart { restart: "a" }' > /etc/needrestart/conf.d/99-force-restart.conf 2>/dev/null || true
fi

# --- 1. 基础依赖 ---
apt update -y && apt install jq socat curl wget openssl tar grep chrony -y
ufw disable >/dev/null 2>&1 || true
iptables -P INPUT ACCEPT && iptables -F

# --- 2. 优化配置 (针对苹果刷 TikTok 调优) ---
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

# --- 3. 安装 Sing-box 1.10.7 ---
cpu=$(uname -m)
[ "$cpu" = "x86_64" ] && cpu="amd64" || cpu="arm64"
sbcore='1.10.7'
sbname="sing-box-$sbcore-linux-$cpu"
mkdir -p /etc/s-box

curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 5 "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
mv /etc/s-box/$sbname/sing-box /etc/s-box/sing-box
rm -rf /etc/s-box/{sing-box.tar.gz,$sbname}
chmod +x /etc/s-box/sing-box

# --- 4. 密钥暴力提取 (修复横杠私钥问题) ---
# 这一步改用 sed 提取，无视特殊字符
/etc/s-box/sing-box generate reality-keypair > /tmp/sb_keys.txt
private_key=$(grep -i "Private key:" /tmp/sb_keys.txt | sed 's/.*: //' | tr -d '[:space:]')
public_key=$(grep -i "Public key:" /tmp/sb_keys.txt | sed 's/.*: //' | tr -d '[:space:]')
rm -f /tmp/sb_keys.txt

short_id=$(/etc/s-box/sing-box generate rand --hex 4)
uuid=$(/etc/s-box/sing-box generate uuid)
IP=$(curl -s4m5 icanhazip.com)

# --- 5. 写配置文件 ---
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

# --- 7. 最终精准输出 (Clash 2/4/6 空格缩进) ---
clear
echo "======================================================"
echo "🍎 TikTok 矩阵版 V10.0 部署成功！"
echo "======================================================"
echo -e "\033[33mVLESS 分享链接:\033[0m"
echo "vless://$uuid@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=$public_key&sid=$short_id#TK-$IP"

echo -e "\n\033[33mClash / Nikki 配置 (直接复制使用):\033[0m"
printf "  - name: \"TK-%s\"\n" "$IP"
printf "    type: vless\n"
printf "    server: %s\n" "$IP"
printf "    port: 443\n"
printf "    uuid: %s\n" "$uuid"
printf "    udp: true\n"
printf "    tls: true\n"
printf "    flow: xtls-rprx-vision\n"
printf "    servername: www.apple.com\n"
printf "    reality-opts:\n"
printf "      public-key: %s\n" "$public_key"
printf "      short-id: %s\n" "$short_id"
printf "    client-fingerprint: safari\n"
echo "======================================================"
