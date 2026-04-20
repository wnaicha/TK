# 1. 确保定时重启任务存在 (每天凌晨0:00)
(crontab -l 2>/dev/null | grep -v "/sbin/reboot"; echo "0 0 * * * /sbin/reboot") | crontab -

# 2. 获取各项系统数据
cc=$(sysctl -n net.ipv4.tcp_congestion_control); \
qdisc=$(sysctl -n net.core.default_qdisc); \
mod_status=$(lsmod | grep -q "bbr" && echo -e "\033[32m已加载\033[0m" || echo -e "\033[31m未加载\033[0m"); \
up_time=$(uptime -p | sed 's/up //'); \
boot_time=$(who -b | awk '{print $3,$4}'); \
reboot_job=$(crontab -l 2>/dev/null | grep "/sbin/reboot" || echo "未设置"); \
snmp_file="/proc/net/snmp"; \
out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' $snmp_file | head -n 1); \
retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' $snmp_file | head -n 1); \
data=$(grep "Tcp:" $snmp_file | tail -n 1); \
out_segs=$(echo $data | awk "{print \$$out_idx}"); \
retr_segs=$(echo $data | awk "{print \$$retr_idx}"); \
rate=$(awk "BEGIN {printf \"%.4f\", ($retr_segs/$out_segs)*100}"); \
clear; \
echo "==============================================="; \
printf "🚀 系统运行时间 : \033[36m%s\033[0m\n" "$up_time"; \
printf "📅 上次启动时间 : \033[36m%s\033[0m\n" "$boot_time"; \
printf "⏰ 定时重启计划 : \033[32m%s\033[0m\n" "$reboot_job"; \
echo "-----------------------------------------------"; \
printf "✅ BBR 状态     : \033[32m%s\033[0m\n" "$cc"; \
printf "✅ 队列算法     : \033[32m%s\033[0m\n" "$qdisc"; \
printf "✅ 内核模块     : %b\n" "$mod_status"; \
printf "✅ 重 传 率     : \033[33m%s%%\033[0m\n" "$rate"; \
echo "==============================================="; \
printf "\n"
