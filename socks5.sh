#!/usr/bin/env bash
# =============================================================
#  一键搭建 SOCKS5 代理服务器（dante-server 方案）
#  支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux
#
#  默认一键（推荐，全自动随机）:
#      sudo bash install.sh
#      -> 自动生成 随机端口(自动避让已占用端口) + 随机账号/密码，
#         自动放行防火墙，结束直接打印 socks5:// 链接，复制即用。
#
#  自定义端口/账号:
#      sudo bash install.sh -p 1080 -u myuser -P 'mypass' -i eth0
#      sudo bash install.sh -u a -P aaa -u b -P bbb     # 多账号
#      sudo bash install.sh -u myuser                   # 只指定用户名，密码随机
#  卸载清理:
#      sudo bash install.sh --uninstall
#
#  环境变量(可选):
#      SOCKS_USERS="u1:p1,u2:p2"  SOCKS_PORT=1080  SOCKS_IFACE=eth0
# =============================================================
set -euo pipefail

STATE=/etc/socks5_install.conf

# ---------------- 参数解析 ----------------
PORT="${SOCKS_PORT:-}"
IFACE="${SOCKS_IFACE:-}"
declare -a USERS=()
UNINSTALL=0

usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && !/^#/{exit}' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)   PORT="$2"; shift 2 ;;
    -i|--iface)  IFACE="$2"; shift 2 ;;
    -u|--user)   USERS+=("$2"); shift 2 ;;
    -P|--pass)
      if [[ ${#USERS[@]} -eq 0 ]]; then echo "错误: -P 需要先跟 -u" >&2; exit 1; fi
      USERS+=("$2"); shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

# ---------------- 工具函数 ----------------
log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[1;36m[..]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS="$ID"
  else
    OS="centos"
  fi
  case "$OS" in
    ubuntu|debian|centos|rhel|rocky|almalinux|kali|linuxmint) ;;
    *) die "暂不支持的系统: $OS (仅支持 Debian/Ubuntu/CentOS 系)" ;;
  esac
}

detect_iface() {
  if [[ -n "$IFACE" ]]; then echo "$IFACE"; return; fi
  local dev
  dev="$(ip -4 route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
  [[ -z "$dev" ]] && dev="$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $8; exit}')"
  [[ -z "$dev" ]] && dev="eth0"
  echo "$dev"
}

public_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -z "$ip" ]] && ip="127.0.0.1"
  echo "$ip"
}

# 端口是否已被占用
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$p\$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$p\$" && return 0
  else
    (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null && return 0
  fi
  return 1
}

# 在 20000~59999 之间挑一个没被占用的端口
random_port() {
  local p i
  for i in $(seq 1 200); do
    p=$(( (RANDOM % 40000) + 20000 ))
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

rand_pass() { head -c 128 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; }

# 随机用户名：小写字母开头 + 数字，且不与系统已有用户冲突
rand_user() {
  local u i
  for i in $(seq 1 50); do
    u="u$(head -c 128 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 7)"
    if ! id "$u" >/dev/null 2>&1; then echo "$u"; return 0; fi
  done
  echo "socks$(date +%s)"
}

# 补齐缺失密码；若完全没给账号，就生成随机账号+密码
prepare_creds() {
  local new=() i u p
  i=0
  while [[ $i -lt ${#USERS[@]} ]]; do
    u="${USERS[$i]}"
    if [[ $((i+1)) -lt ${#USERS[@]} ]]; then
      p="${USERS[$((i+1))]}"
    else
      p="$(rand_pass 16)"
      info "为账号 $u 随机生成密码"
    fi
    new+=("$u" "$p")
    i=$((i+2))
  done
  if [[ ${#new[@]} -gt 0 ]]; then USERS=("${new[@]}"); fi
  if [[ ${#USERS[@]} -eq 0 ]]; then
    USERS=("$(rand_user)" "$(rand_pass 16)")
    info "未指定账号，已随机生成 用户名/密码"
  fi
}

save_state() {
  umask 077
  : > "$STATE"
  echo "PORT=$PORT" >> "$STATE"
  echo "IFACE=$DEV" >> "$STATE"
  local i=0
  while [[ $i -lt ${#USERS[@]} ]]; do
    printf 'CRED=%q:%q\n' "${USERS[$i]}" "${USERS[$((i+1))]}" >> "$STATE"
    i=$((i+2))
  done
}

load_state() {
  # 读取上次安装记录，便于 --uninstall 清理随机生成的账号
  [[ -f "$STATE" ]] || return 0
  . "$STATE"
  USERS=()
  local line cred u p
  while IFS= read -r line; do
    [[ "$line" == CRED=* ]] || continue
    cred="${line#CRED=}"
    u="${cred%%:*}"; p="${cred#*:}"
    USERS+=("$u" "$p")
  done < "$STATE"
}

# ---------------- 卸载 ----------------
if [[ "$UNINSTALL" -eq 1 ]]; then
  is_root || die "请用 root 运行: sudo bash install.sh --uninstall"
  load_state
  log "停止并移除 dante 服务..."
  systemctl stop danted 2>/dev/null || service danted stop 2>/dev/null || true
  systemctl disable danted 2>/dev/null || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y dante-server >/dev/null 2>&1 || true
  else
    yum remove -y dante-server >/dev/null 2>&1 || true
  fi
  rm -f /etc/danted.conf /etc/dante.conf
  # 清理本脚本创建的 socks 系统用户（USERS 为 user/pass 交替，只删 user 位）
  local i=0
  while [[ $i -lt ${#USERS[@]} ]]; do
    userdel -r "${USERS[$i]}" 2>/dev/null || true
    i=$((i+2))
  done
  rm -f "$STATE"
  log "卸载完成"
  exit 0
fi

# ---------------- 主体 ----------------
is_root || die "请用 root 运行: sudo bash install.sh"
detect_os
DEV="$(detect_iface)"

# 1. 端口：没指定就随机选一个未占用的
if [[ -z "$PORT" ]]; then
  PORT="$(random_port)" || die "20000~59999 范围内找不到空闲端口，请用 -p 手动指定"
  info "自动选择空闲端口: $PORT"
else
  if port_in_use "$PORT"; then
    die "端口 $PORT 已被占用，请换一个，或不指定端口使用随机模式"
  fi
fi

# 2. 账号：没指定就随机生成
prepare_creds

log "系统: $OS, 出口网卡: $DEV, 端口: $PORT"

# 3. 安装 dante-server
info "安装 dante-server ..."
if [[ "$OS" == "debian" || "$OS" == "ubuntu" || "$OS" == "kali" || "$OS" == "linuxmint" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server
  CONF="/etc/danted.conf"
else
  command -v yum >/dev/null 2>&1 || die "未找到 yum"
  yum install -y epel-release || true
  yum install -y dante-server
  CONF="/etc/dante.conf"
fi

# 4. 生成配置
info "生成配置 $CONF ..."
cat > "$CONF" <<CONF
# Generated by socks5/install.sh
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = $PORT
external: $DEV

clientmethod: none
socksmethod: username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
CONF

# 5. 创建账号（系统用户，禁止登录）
info "创建 SOCKS5 账号 ..."
local i=0
while [[ $i -lt ${#USERS[@]} ]]; do
  local u="${USERS[$i]}" p="${USERS[$((i+1))]}"
  if id "$u" >/dev/null 2>&1; then
    echo "$u:$p" | chpasswd
    log "账号已存在, 重置密码: $u / $p"
  else
    useradd -M -s /usr/sbin/nologin "$u" 2>/dev/null \
      || useradd -M -s /sbin/nologin "$u"
    echo "$u:$p" | chpasswd
    log "创建账号: $u / $p"
  fi
  i=$((i+2))
done

# 6. 启动服务
info "启动 danted 服务 ..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable danted
  systemctl restart danted
  sleep 1
  systemctl is-active danted >/dev/null 2>&1 || die "服务启动失败, 查看日志: journalctl -u danted -n 50"
else
  service danted restart
fi

# 7. 防火墙放行
info "放行防火墙端口 $PORT ..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
fi

# 8. 保存安装记录（供卸载清理随机账号）
save_state

# 9. 输出结果
IP="$(public_ip)"
echo ""
log "============================================================"
log " ✅ SOCKS5 搭建完成"
log "    服务器: $IP"
log "    端口:   $PORT"
log ""
local j=0
while [[ $j -lt ${#USERS[@]} ]]; do
  local uu="${USERS[$j]}" pp="${USERS[$((j+1))]}"
  log " ┌────────────────────────────────────────────────"
  log " │ SK5 链接 (直接复制使用):"
  log " │   socks5://$uu:$pp@$IP:$PORT"
  log " │ 测试命令:"
  log " │   curl -x socks5h://$uu:$pp@$IP:$PORT https://api.ipify.org"
  log " └────────────────────────────────────────────────"
  j=$((j+2))
done
log ""
log " 提示: 账号密码只在本次显示，请立即保存。"
log " 若外网连不上，请检查云服务器安全组是否放行了 TCP $PORT。"
log " 再加账号: sudo bash install.sh -u 新用户名 -P 密码"
log " 卸载清理: sudo bash install.sh --uninstall"
log "============================================================"
