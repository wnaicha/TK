snmp_file="/proc/net/snmp"; \
out_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="OutSegs") print i}' $snmp_file | head -n 1); \
retr_idx=$(awk '/Tcp:/ {for(i=1;i<=NF;i++) if($i=="RetransSegs") print i}' $snmp_file | head -n 1); \
data=$(grep "Tcp:" $snmp_file | tail -n 1); \
out_segs=$(echo $data | awk "{print \$$out_idx}"); \
retr_segs=$(echo $data | awk "{print \$$retr_idx}"); \
rate=$(awk "BEGIN {printf \"%.4f\", ($retr_segs/$out_segs)*100}"); \
\
if (( $(echo "$rate < 0.5" | bc -l) )); then
    level="\033[42;37m ★ 极佳 (健康) \033[0m";
elif (( $(echo "$rate < 1.5" | bc -l) )); then
    level="\033[44;37m ★ 良好 (亚健康) \033[0m";
elif (( $(echo "$rate < 3.0" | bc -l) )); then
    level="\033[43;30m ⚡ 警告 (线路波动) \033[0m";
else
    level="\033[41;37m ❌ 危险 (极高限流风险) \033[0m";
fi; \
\
clear; \
echo "==============================================="; \
echo "📊 TikTok 环境网络质量检测"; \
echo "==============================================="; \
printf "📤 总 发 包 : %s\n" "$out_segs"; \
printf "🔄 重 传 包 : %s\n" "$retr_segs"; \
printf "📉 重 传 率 : \033[1m%s%%\033[0m\n" "$rate"; \
printf "🚦 质量等级 : %b\n" "$level"; \
echo "==============================================="; \
printf "\n"
