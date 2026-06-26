#!/bin/bash
# ===============================================================
#  TikTok 矩阵 - 服务器质量一键检测  (tk-check.sh)
#  用法:
#     bash tk-check.sh              # 基础检测
#     bash tk-check.sh 119.x.x.x    # 额外对该客户端IP做丢包/路由测试
#  说明: 只读检测，不改任何配置。建议 root 运行以读全连接信息。
# ===============================================================

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
TARGET="$1"
SAMPLE=5   # 重传率采样秒数

line(){ echo "==============================================="; }

# ---------- 取 /proc/net/snmp 里的 TCP 字段 ----------
tcp_field(){
  awk -v f="$1" '
    /^Tcp:/ { if(!hdr){for(i=1;i<=NF;i++)idx[$i]=i;hdr=1} else {print $(idx[f]);exit} }
  ' /proc/net/snmp
}

clear
line; echo -e "${B}📊 TikTok 服务器质量检测${N}"; line

# ---------- 基本信息 ----------
IP=$(curl -s4m5 https://api.ipify.org 2>/dev/null || curl -s4m5 https://icanhazip.com 2>/dev/null)
IP=$(echo "$IP" | tr -d '[:space:]'); [ -z "$IP" ] && IP="<取不到>"
HOST=$(hostname)
UP=$(uptime -p 2>/dev/null | sed 's/up //')
LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
MEM=$(free -m | awk '/Mem:/{printf "%d/%dMB (%.0f%%)", $3,$2,$3/$2*100}')
printf "🖥  主机      : ${C}%s${N}\n" "$HOST"
printf "🌐 公网IP    : ${C}%s${N}\n" "$IP"
printf "🚀 运行时间  : %s\n" "$UP"
printf "📈 负载(1/5/15): %s\n" "$LOAD"
printf "🧠 内存      : %s\n" "$MEM"

# ---------- 服务状态 ----------
line; echo -e "${B}🔧 服务状态${N}"; line
for svc in sing-box sb-sub; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    printf "  %-10s : ${G}● running${N}\n" "$svc"
  else
    printf "  %-10s : ${R}✗ 未运行${N}  (journalctl -u %s -n 20)\n" "$svc" "$svc"
  fi
done
# 8080 订阅端口监听检查
if ss -tlnH 2>/dev/null | grep -q ':8080 '; then
  printf "  %-10s : ${G}● 监听中${N}\n" "订阅:8080"
else
  printf "  %-10s : ${R}✗ 没在监听${N}\n" "订阅:8080"
fi

# ---------- BBR / 内核 ----------
line; echo -e "${B}⚙️  内核优化${N}"; line
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QD=$(sysctl -n net.core.default_qdisc 2>/dev/null)
[ "$CC" = "bbr" ] && CCS="${G}$CC${N}" || CCS="${R}$CC (建议 bbr)${N}"
lsmod | grep -q bbr && BBRM="${G}已加载${N}" || BBRM="${Y}未加载(可能已内建)${N}"
printf "  拥塞算法   : %b\n" "$CCS"
printf "  队列算法   : ${C}%s${N}\n" "$QD"
printf "  BBR 模块   : %b\n" "$BBRM"

# ---------- 重传率(采样 N 秒，反映当前质量) ----------
line; echo -e "${B}📉 重传率 (实时 ${SAMPLE}s 采样)${N}"; line
O1=$(tcp_field OutSegs); R1=$(tcp_field RetransSegs)
sleep "$SAMPLE"
O2=$(tcp_field OutSegs); R2=$(tcp_field RetransSegs)
RATE=$(awk -v a="$O1" -v b="$O2" -v c="$R1" -v d="$R2" \
  'BEGIN{ds=b-a;dr=d-c; if(ds<=0)print"0.0000"; else printf"%.4f",dr/ds*100}')
RINT=$(awk -v r="$RATE" 'BEGIN{printf"%d",r*10000}')
if   [ "$RINT" -lt 10000 ]; then LV="${G}★ 极佳 (健康)${N}"
elif [ "$RINT" -lt 30000 ]; then LV="${C}★ 良好 (亚健康)${N}"
elif [ "$RINT" -lt 50000 ]; then LV="${Y}⚡ 警告 (线路波动)${N}"
else                             LV="${R}❌ 危险 (高限流风险)${N}"
fi
printf "  采样发包   : %s 段\n" "$((O2-O1))"
printf "  采样重传   : %s 段\n" "$((R2-R1))"
printf "  实时重传率 : ${B}%s%%${N}   %b\n" "$RATE" "$LV"
# 自开机累计值(参考)
CUM=$(awk -v c="$R2" -v d="$O2" 'BEGIN{if(d<=0)print"0";else printf"%.4f",c/d*100}')
printf "  累计重传率 : %s%% (自开机参考)\n" "$CUM"

# ---------- 当前连接 & 谁在重传 ----------
line; echo -e "${B}🔗 客户端连接 & 重传 TOP${N}"; line
CONN=$(ss -tnH state established '( sport = :443 or sport = :https )' 2>/dev/null | wc -l)
printf "  当前已连接客户端: ${C}%s${N} 个\n" "$CONN"
echo "  -----------------------------------------------"
echo "  对端IP:端口             重传/总段      占比     RTT"
ss -tien 2>/dev/null | awk '
  /^ESTAB/ { peer=$5; next }
  /retrans:/ {
    r=-1; d=-1; rtt="";
    if (match($0,/retrans:[0-9]+\/[0-9]+/)) { s=substr($0,RSTART,RLENGTH); sub("retrans:","",s); split(s,A,"/"); r=A[2] }
    if (match($0,/data_segs_out:[0-9]+/))   { s=substr($0,RSTART,RLENGTH); sub("data_segs_out:","",s); d=s+0 }
    if (match($0,/ rtt:[0-9.]+/))           { s=substr($0,RSTART,RLENGTH); sub(" rtt:","",s); rtt=s }
    if (d>0 && r>=0) { pct=r/d*100; printf "%s|%d|%d|%.1f|%s\n", peer, r, d, pct, rtt }
  }' | sort -t'|' -k4 -nr | head -8 | awk -F'|' '
  { color=($4>=5?"\033[31m":($4>=3?"\033[33m":"\033[32m"));
    printf "  %-22s  %5d/%-7d  %s%5.1f%%\033[0m  %sms\n", $1,$2,$3,color,$4,$5 }'
[ "$CONN" -eq 0 ] && echo -e "  ${Y}(暂无客户端连接，重传统计需有流量才准)${N}"

# ---------- 可选: 对指定客户端做丢包/路由测试 ----------
if [ -n "$TARGET" ]; then
  line; echo -e "${B}🎯 到 $TARGET 的丢包/路由${N}"; line
  echo "  [ping 50 包]"
  ping -c 50 -i 0.2 -W 1 "$TARGET" 2>/dev/null | tail -2 | sed 's/^/  /'
  if command -v mtr >/dev/null 2>&1; then
    echo "  [mtr 30 周期]"
    mtr -rwzc 30 "$TARGET" 2>/dev/null | sed 's/^/  /'
  else
    echo -e "  ${Y}未装 mtr，跑路由测试请先: apt install -y mtr-tiny${N}"
  fi
fi

line
echo -e "判读: 重传率 ${G}<1%极佳${N} / ${C}1-3%良好${N} / ${Y}3-5%警告${N} / ${R}>5%危险${N}"
echo -e "重传集中在${B}客户端IP${N}=跨境线路问题(换机房/IP);若想测某客户端加参数: ${C}bash tk-check.sh 客户端IP${N}"
line
