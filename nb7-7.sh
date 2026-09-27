#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ============================================================
# sing-box VLESS + REALITY + Vision Node Manager v2
# Debian / Ubuntu
#
# Defaults:
#   - Latest stable sing-box from official GitHub release
#   - www.apple.com is the first REALITY handshake target
#   - UDP enabled
#   - No global UDP reject
#   - Non-root sing-box service
#   - Transactional config changes + rollback
#   - "nb" management CLI
#
# Important:
#   UDP being enabled on the server does NOT by itself guarantee that a
#   browser/device cannot leak via a direct WebRTC path. Preventing that
#   requires the client/router to prohibit direct bypass traffic.
# ============================================================

BASE="/etc/s-box"
BIN="$BASE/sing-box"
CONF="$BASE/sb.json"
STATE="$BASE/state"
BACKUP="$BASE/backup"
SUB_ROOT="$BASE/sub"
SUB_PORT="${SUB_PORT:-8080}"
SBX_USER="sbxuser"
GITHUB_REPO="SagerNet/sing-box"

mkdir -p "$BASE" "$STATE" "$BACKUP" "$SUB_ROOT"

log(){ printf '\033[1;36m[+]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行"; }
need_root

trap 'printf "\n\033[1;31m[✗]\033[0m 安装/操作失败：line=%s command=%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---------- helpers ----------
state_get(){ [[ -f "$STATE/$1" ]] && cat "$STATE/$1" || true; }
state_set(){ printf '%s\n' "$2" > "$STATE/$1"; chmod 640 "$STATE/$1"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
json_escape(){ jq -Rn --arg x "$1" '$x'; }

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686) echo 386 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl jq openssl tar chrony qrencode \
    iproute2 python3 libcap2-bin procps >/dev/null
  systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
}

public_ipv4() {
  local ip=""
  ip="$(curl -fsS4m5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS4m5 https://icanhazip.com 2>/dev/null || true)"
  ip="${ip//$'\n'/}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无法获取公网 IPv4"
  printf '%s\n' "$ip"
}

latest_stable() {
  local v
  v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" |
       jq -r '.tag_name // empty' | sed 's/^v//')"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法获取 sing-box stable 版本"
  printf '%s\n' "$v"
}

download_singbox() {
  local ver="${1:-}" arch asset url tmp api digest expected actual dir
  [[ -n "$ver" ]] || ver="$(latest_stable)"
  arch="$(arch_name)"
  asset="sing-box-${ver}-linux-${arch}.tar.gz"
  url="https://github.com/${GITHUB_REPO}/releases/download/v${ver}/${asset}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' RETURN

  log "下载官方 sing-box v${ver} (${arch})"
  curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$tmp/$asset" "$url"

  log "获取官方 release digest"
  api="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/v${ver}")"
  digest="$(jq -r --arg n "$asset" '.assets[]? | select(.name==$n) | .digest // empty' <<<"$api")"
  expected="${digest#sha256:}"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "未取得官方 SHA256 digest；为安全起见停止安装"
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "SHA256 校验失败"

  tar -xzf "$tmp/$asset" -C "$tmp"
  [[ -x "$tmp/sing-box-${ver}-linux-${arch}/sing-box" ]] || die "压缩包内容异常"
  install -m 0755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$BIN.new"
  "$BIN.new" version >/dev/null
  mv -f "$BIN.new" "$BIN"
  state_set version "$ver"
  ok "sing-box v${ver} 安装完成"
}

ensure_user() {
  id "$SBX_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SBX_USER"
}

apply_sysctl() {
  cat >/etc/sysctl.d/99-sing-box.conf <<'EOF'
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
EOF
  modprobe tcp_bbr >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || warn "部分 sysctl 未生效，请检查内核支持"
}

# ---------- REALITY target ----------
REALITY_CANDIDATES=(
  "www.apple.com"
  "www.icloud.com"
  "itunes.apple.com"
  "www.microsoft.com"
  "www.cloudflare.com"
  "www.google.com"
)

test_sni() {
  local d="$1" out
  out="$(timeout 7 openssl s_client -connect "${d}:443" -servername "$d" -tls1_3 \
      -verify_return_error </dev/null 2>&1)" || return 1
  grep -Eq 'Verify return code:[[:space:]]*0 \(ok\)' <<<"$out"
}

choose_sni_auto() {
  local d
  for d in "${REALITY_CANDIDATES[@]}"; do
    printf '  测试 %-28s ' "$d" >&2
    if test_sni "$d"; then
      printf '\033[32mOK\033[0m\n' >&2
      printf '%s\n' "$d"
      return 0
    else
      printf '\033[31mFAIL\033[0m\n' >&2
    fi
  done
  return 1
}

list_sni() {
  local i=1 d
  echo "REALITY 候选（Apple 优先）"
  for d in "${REALITY_CANDIDATES[@]}"; do
    printf '  %d) %-28s ' "$i" "$d"
    test_sni "$d" && printf '\033[32m✓\033[0m\n' || printf '\033[31m✗\033[0m\n'
    ((i++))
  done
}

# ---------- identity ----------
ensure_identity() {
  local kp
  if [[ ! -s "$STATE/uuid" ]]; then
    state_set uuid "$("$BIN" generate uuid)"
  fi
  if [[ ! -s "$STATE/reality_private" || ! -s "$STATE/reality_public" ]]; then
    kp="$("$BIN" generate reality-keypair)"
    state_set reality_private "$(awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$kp")"
    state_set reality_public  "$(awk -F': ' 'tolower($1) ~ /public/  {print $2; exit}' <<<"$kp")"
  fi
  if [[ ! -s "$STATE/short_id" ]]; then
    state_set short_id "$("$BIN" generate rand --hex 8)"
  fi
}

# ---------- config ----------
render_config() {
  local outfile="$1"
  local port uuid sni priv
  port="$(state_get port)"
  uuid="$(state_get uuid)"
  sni="$(state_get sni)"
  priv="$(state_get reality_private)"

  jq -n \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg priv "$priv" \
'{
  log: {level:"warn", timestamp:true},
  inbounds: [{
    type:"vless",
    tag:"proxy-in",
    listen:"0.0.0.0",
    listen_port:$port,
    users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
    tls:{
      enabled:true,
      server_name:$sni,
      reality:{
        enabled:true,
        handshake:{server:$sni, server_port:443},
        private_key:$priv,
        short_id:[]
      }
    }
  }],
  outbounds:[{type:"direct", tag:"direct"}],
  route:{final:"direct"}
}' >"$outfile"

  # short_id is intentionally inserted after construction for an array value.
  local sid tmp
  sid="$(state_get short_id)"
  tmp="${outfile}.sid"
  jq --arg sid "$sid" '.inbounds[0].tls.reality.short_id=[$sid]' "$outfile" >"$tmp"
  mv "$tmp" "$outfile"
}

backup_now() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP/$stamp"
  [[ -f "$CONF" ]] && cp -a "$CONF" "$BACKUP/$stamp/sb.json"
  cp -a "$STATE" "$BACKUP/$stamp/state"
  printf '%s\n' "$BACKUP/$stamp"
}

apply_config() {
  local tmp bak
  tmp="$(mktemp "$BASE/sb.json.XXXXXX")"
  render_config "$tmp"
  chown "$SBX_USER:$SBX_USER" "$tmp"
  chmod 640 "$tmp"

  "$BIN" check -c "$tmp" || { rm -f "$tmp"; die "新配置未通过 sing-box check"; }

  bak="$(backup_now)"
  mv -f "$tmp" "$CONF"
  chown "$SBX_USER:$SBX_USER" "$CONF"
  chmod 640 "$CONF"

  if systemctl restart sing-box && sleep 1 && systemctl is-active --quiet sing-box; then
    generate_subscription
    ok "配置已应用"
  else
    warn "启动失败，自动回滚"
    [[ -f "$bak/sb.json" ]] && cp -a "$bak/sb.json" "$CONF"
    rm -rf "$STATE"
    cp -a "$bak/state" "$STATE"
    systemctl restart sing-box || true
    die "已恢复上一份配置"
  fi
}

# ---------- subscription ----------
sub_token() {
  local t
  t="$(state_get sub_token)"
  if [[ -z "$t" ]]; then
    t="$(openssl rand -hex 24)"
    state_set sub_token "$t"
  fi
  printf '%s\n' "$t"
}

generate_subscription() {
  local ip port uuid sni pub sid name token dir
  ip="$(state_get server_ip)"
  port="$(state_get port)"
  uuid="$(state_get uuid)"
  sni="$(state_get sni)"
  pub="$(state_get reality_public)"
  sid="$(state_get short_id)"
  name="$(state_get node_name)"
  token="$(sub_token)"
  dir="$SUB_ROOT/$token"
  mkdir -p "$dir"

  cat >"$dir/proxy.yaml" <<EOF
proxies:
  - name: "$name"
    type: vless
    server: $ip
    port: $port
    uuid: $uuid
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $sni
    client-fingerprint: safari
    reality-opts:
      public-key: $pub
      short-id: $sid
EOF
  chown -R "$SBX_USER:$SBX_USER" "$SUB_ROOT"
  find "$SUB_ROOT" -type d -exec chmod 750 {} +
  find "$SUB_ROOT" -type f -exec chmod 640 {} +
}

install_sub_server() {
  cat >"$BASE/sub_server.py" <<'PY'
#!/usr/bin/env python3
import http.server, os, posixpath, socketserver, sys, urllib.parse

PORT=int(sys.argv[1])
BASE=os.path.realpath("/etc/s-box/sub")

class Handler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        self.send_error(403)
        return None
    def translate_path(self, path):
        path=urllib.parse.unquote(path.split("?",1)[0].split("#",1)[0])
        path=posixpath.normpath(path)
        candidate=os.path.realpath(os.path.join(BASE,path.lstrip("/")))
        if candidate != BASE and not candidate.startswith(BASE+os.sep):
            return os.path.join(BASE,"__denied__")
        return candidate
    def log_message(self, fmt, *args):
        pass

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True

with Server(("0.0.0.0",PORT),Handler) as httpd:
    httpd.serve_forever()
PY
  chmod 750 "$BASE/sub_server.py"
  chown "$SBX_USER:$SBX_USER" "$BASE/sub_server.py"
}

install_services() {
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box VLESS REALITY Vision
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SBX_USER
Group=$SBX_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription server
After=network-online.target
Wants=network-online.target

[Service]
User=$SBX_USER
Group=$SBX_USER
WorkingDirectory=$SUB_ROOT
ExecStart=/usr/bin/python3 $BASE/sub_server.py $SUB_PORT
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box sb-sub >/dev/null
}

# ---------- firewall ----------
open_ports() {
  local port
  port="$(state_get port)"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/tcp" >/dev/null || true
    ufw allow "${port}/udp" >/dev/null || true
    ufw allow "${SUB_PORT}/tcp" >/dev/null || true
  fi
  # Do not silently rewrite nftables/iptables policy. Cloud/VPS firewall may
  # still need TCP+UDP proxy port and TCP subscription port opened manually.
}

# ---------- management CLI ----------
write_nb() {
  cat >/usr/local/bin/nb <<'NB'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=/etc/s-box
BIN="$BASE/sing-box"
CONF="$BASE/sb.json"
STATE="$BASE/state"
BACKUP="$BASE/backup"
SUB_ROOT="$BASE/sub"
SUB_PORT=8080
SELF=/usr/local/libexec/nb-core

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root"; exit 1; }
[[ -x "$SELF" ]] || { echo "nb-core 不存在"; exit 1; }
exec "$SELF" "${@:-menu}"
NB
  chmod 755 /usr/local/bin/nb

  # Reuse this installed script as the core implementation.
  install -m 0755 "$0" /usr/local/libexec/nb-core
}

show_info() {
  local ip port uuid sni pub sid name ver token link
  ip="$(state_get server_ip)"; port="$(state_get port)"; uuid="$(state_get uuid)"
  sni="$(state_get sni)"; pub="$(state_get reality_public)"; sid="$(state_get short_id)"
  name="$(state_get node_name)"; ver="$("$BIN" version 2>/dev/null | head -1 || true)"
  token="$(sub_token)"
  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&encryption=none&pbk=${pub}&fp=safari&sni=${sni}&sid=${sid}&flow=xtls-rprx-vision#${name}"

  echo "=================================================="
  echo " Node : $name"
  echo " Core : $ver"
  echo " State: $(systemctl is-active sing-box 2>/dev/null || true)"
  echo " SNI  : $sni"
  echo " Port : $port (TCP/UDP)"
  echo " UDP  : enabled"
  echo " IP   : $ip"
  echo "=================================================="
  echo "$link"
  echo
  echo "Mihomo subscription:"
  echo "http://${ip}:${SUB_PORT}/${token}/proxy.yaml"
  echo "=================================================="
}

show_qr() {
  local ip port uuid sni pub sid name link
  ip="$(state_get server_ip)"; port="$(state_get port)"; uuid="$(state_get uuid)"
  sni="$(state_get sni)"; pub="$(state_get reality_public)"; sid="$(state_get short_id)"
  name="$(state_get node_name)"
  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&encryption=none&pbk=${pub}&fp=safari&sni=${sni}&sid=${sid}&flow=xtls-rprx-vision#${name}"
  echo "$link"
  command -v qrencode >/dev/null && qrencode -t ansiutf8 "$link"
}

change_sni() {
  local d n
  list_sni
  echo "  m) 手动输入"
  read -r -p "请选择（默认 1 = www.apple.com）: " n
  n="${n:-1}"
  if [[ "$n" == "m" || "$n" == "M" ]]; then
    read -r -p "输入域名: " d
    [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名格式错误"
    test_sni "$d" || die "该目标 TLS1.3/证书检测失败"
  elif [[ "$n" =~ ^[1-6]$ ]]; then
    d="${REALITY_CANDIDATES[$((n-1))]}"
    test_sni "$d" || die "该候选当前检测失败"
  else
    die "选择无效"
  fi
  state_set sni "$d"
  apply_config
}

change_port() {
  local p old
  old="$(state_get port)"
  read -r -p "新端口（当前 $old）: " p
  valid_port "$p" || die "端口无效"
  [[ "$p" != "$SUB_PORT" ]] || die "不能与订阅端口冲突"
  state_set port "$p"
  open_ports
  apply_config
}

change_name() {
  local n
  read -r -p "新节点名称: " n
  [[ -n "$n" ]] || die "名称不能为空"
  state_set node_name "$n"
  generate_subscription
  ok "节点名称已修改"
}

update_core() {
  local latest current bak
  latest="$(latest_stable)"
  current="$("$BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ "$latest" != "$current" ]] || { ok "已经是最新 stable v$current"; return; }
  bak="$(backup_now)"
  cp -a "$BIN" "$bak/sing-box.bin"
  download_singbox "$latest"
  if "$BIN" check -c "$CONF" && systemctl restart sing-box && sleep 1 && systemctl is-active --quiet sing-box; then
    ok "已更新到 v$latest"
  else
    warn "更新失败，回滚核心"
    cp -a "$bak/sing-box.bin" "$BIN"
    systemctl restart sing-box || true
    die "已恢复旧核心"
  fi
}

repair_install() {
  install_deps
  ensure_user
  [[ -x "$BIN" ]] || download_singbox
  "$BIN" check -c "$CONF"
  install_sub_server
  install_services
  generate_subscription
  open_ports
  systemctl restart sing-box sb-sub
  ok "修复完成"
}

rebuild_identity() {
  local ans kp
  read -r -p "这会更换 UUID/REALITY 密钥，现有客户端将失效。输入 YES 继续: " ans
  [[ "$ans" == YES ]] || return 0
  state_set uuid "$("$BIN" generate uuid)"
  kp="$("$BIN" generate reality-keypair)"
  state_set reality_private "$(awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$kp")"
  state_set reality_public "$(awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$kp")"
  state_set short_id "$("$BIN" generate rand --hex 8)"
  apply_config
}

restore_backup() {
  local arr choice dir
  mapfile -t arr < <(find "$BACKUP" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -20)
  ((${#arr[@]})) || die "没有备份"
  for i in "${!arr[@]}"; do printf '%d) %s\n' "$((i+1))" "${arr[$i]}"; done
  read -r -p "选择备份: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || die "无效选择"
  (( choice >= 1 && choice <= ${#arr[@]} )) || die "无效选择"
  dir="$BACKUP/${arr[$((choice-1))]}"
  [[ -d "$dir/state" ]] || die "备份不完整"
  rm -rf "$STATE"; cp -a "$dir/state" "$STATE"
  render_config "$CONF.new"
  "$BIN" check -c "$CONF.new"
  mv "$CONF.new" "$CONF"
  chown sbxuser:sbxuser "$CONF"; chmod 640 "$CONF"
  generate_subscription
  systemctl restart sing-box
  ok "恢复完成"
}

network_test() {
  echo "== sing-box =="
  "$BIN" check -c "$CONF" && echo "config: OK"
  systemctl --no-pager --full status sing-box | sed -n '1,12p' || true
  echo
  echo "== REALITY target =="
  test_sni "$(state_get sni)" && echo "$(state_get sni): TLS1.3/verify OK" || echo "$(state_get sni): FAIL"
  echo
  echo "== UDP note =="
  echo "Server UDP is enabled. WebRTC leak prevention must also block direct/bypass traffic on the client/router."
}

menu() {
  while true; do
    clear
    show_info
    cat <<'EOF'
1) 查看节点/分享信息
2) 二维码
3) 修改 REALITY SNI
4) 修改监听端口
5) 修改节点名称
6) 网络/配置测试
7) 查看日志
8) 重启 sing-box
9) 更新 stable 核心
10) 修复/重装程序（保留节点身份）
11) 重建节点身份（UUID/REALITY）
12) 创建备份
13) 恢复备份
0) 退出
EOF
    read -r -p "请选择: " x
    case "$x" in
      1) show_info ;;
      2) show_qr ;;
      3) change_sni ;;
      4) change_port ;;
      5) change_name ;;
      6) network_test ;;
      7) journalctl -u sing-box -n 100 --no-pager ;;
      8) systemctl restart sing-box && ok "已重启" ;;
      9) update_core ;;
      10) repair_install ;;
      11) rebuild_identity ;;
      12) backup_now ;;
      13) restore_backup ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
    echo; read -r -p "回车继续..."
  done
}

# ---------- command dispatch ----------
cmd="${1:-install}"
case "$cmd" in
  menu) menu ;;
  info|status) show_info ;;
  qr) show_qr ;;
  sni) change_sni ;;
  port) change_port ;;
  name) change_name ;;
  test) network_test ;;
  logs) journalctl -u sing-box -n "${2:-100}" --no-pager ;;
  restart) systemctl restart sing-box; ok "已重启" ;;
  update) update_core ;;
  reinstall|repair) repair_install ;;
  rebuild) rebuild_identity ;;
  backup) backup_now ;;
  restore) restore_backup ;;
  install)
    install_deps
    ensure_user
    apply_sysctl

    # Core: use explicit SB_VERSION if supplied, otherwise latest stable.
    ver="${SB_VERSION:-$(latest_stable)}"
    download_singbox "$ver"

    # Initial state. Existing values are preserved on rerun.
    [[ -s "$STATE/server_ip" ]] || state_set server_ip "$(public_ipv4)"
    [[ -s "$STATE/node_name" ]] || {
      read -r -p "节点名称 [TK-US-Reality]: " v
      state_set node_name "${v:-TK-US-Reality}"
    }
    [[ -s "$STATE/port" ]] || {
      read -r -p "代理端口 [443]: " v
      v="${v:-443}"
      valid_port "$v" || die "端口无效"
      [[ "$v" != "$SUB_PORT" ]] || die "代理端口不能与订阅端口冲突"
      state_set port "$v"
    }
    ensure_identity
    sub_token >/dev/null

    if [[ ! -s "$STATE/sni" ]]; then
      echo "检测 REALITY 目标；www.apple.com 为第一优先..."
      sni="$(choose_sni_auto)" || die "没有可用 REALITY 候选"
      state_set sni "$sni"
    fi

    install_sub_server
    render_config "$CONF"
    "$BIN" check -c "$CONF" || die "初始配置校验失败"
    chown -R "$SBX_USER:$SBX_USER" "$BASE"
    chmod 755 "$BIN"
    chmod 750 "$BASE" "$STATE" "$BACKUP" "$SUB_ROOT"
    chmod 640 "$CONF" "$STATE"/* 2>/dev/null || true

    install_services
    generate_subscription
    open_ports
    systemctl restart sing-box sb-sub
    systemctl is-active --quiet sing-box || die "sing-box 启动失败"
    write_nb

    echo
    ok "安装完成"
    echo "提示：如 VPS/云厂商有安全组，请放行代理端口 TCP+UDP，以及订阅端口 TCP（如确实需要公网订阅）。"
    echo "提示：订阅当前为 HTTP token URL；公网长期使用建议在前面加 HTTPS 反代或限制来源。"
    echo
    show_info
    ;;
  *)
    echo "用法: nb {info|qr|sni|port|name|test|logs|restart|update|reinstall|rebuild|backup|restore}"
    exit 2
    ;;
esac
