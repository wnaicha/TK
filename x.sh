#!/bin/bash
# =========================================================
# TikTok 矩阵环境一键清理脚本 (彻底卸载版)
# =========================================================

systemctl stop sing-box && \
systemctl disable sing-box && \
rm -rf /etc/s-box && \
rm -rf /usr/local/bin/nb && \
rm -f /etc/systemd/system/sing-box.service && \
systemctl daemon-reload && \
echo "-----------------------------------------------" && \
echo "✅ 节点已彻底卸载，相关配置与 nb 命令已清除。" && \
echo "-----------------------------------------------"
