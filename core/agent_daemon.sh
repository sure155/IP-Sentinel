#!/bin/bash

# ==========================================================
# 脚本名称: agent_daemon.sh (受控节点 Webhook 守护进程 V3.1.0)
# 核心功能: 智能防打扰注册、进程自检、部署独立 webhook.py
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
IP_CACHE="${INSTALL_DIR}/core/.last_ip"
WEBHOOK_SCRIPT="${INSTALL_DIR}/core/webhook.py"

[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

# 如果没有配置 TG，说明未开启联控模式，直接退出
[ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0

# 默认 Webhook 监听端口
AGENT_PORT=${AGENT_PORT:-9527}
NODE_NAME=$(hostname | cut -c 1-15)

# --- [重点升级 1: 守护进程防冲突自检] ---
if pgrep -f "webhook.py $AGENT_PORT" > /dev/null; then
  exit 0
fi

# 1. [v3.0.1修复] 严格按照 install.sh 锁定的网络协议 (v4/v6) 获取 IP
RAW_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')

# 为新获取到的 v6 自动加方括号，以确保与之前锁定的格式对齐比对
if [[ "$RAW_IP" == *":"* ]] && [[ "$RAW_IP" != *"["* ]]; then
  AGENT_IP="[${RAW_IP}]"
else
  AGENT_IP="$RAW_IP"
fi

if [ -n "$AGENT_IP" ]; then
  # --- [重点升级 2: 智能防打扰注册机制] ---
  LAST_IP=""
  [ -f "$IP_CACHE" ] && LAST_IP=$(cat "$IP_CACHE" | tr -d '[:space:]')

  # 只有当这是第一次运行，或者公网 IP 发生变动时，才发送 Telegram 申请
  if [ "$AGENT_IP" != "$LAST_IP" ]; then
    REG_MSG="👋 **[边缘节点接入申请]**%0A节点: \`${NODE_NAME}\`%0A地址: \`${AGENT_IP}:${AGENT_PORT}\`%0A%0A⚠️ **安全验证**: 为防止非法节点接入，请长按复制下方代码，并**发送给我**以完成最终授权录入：%0A%0A\`#REGISTER#|${NODE_NAME}|${AGENT_IP}|${AGENT_PORT}|${AGENT_TOKEN}\`"
    
    curl -s -m 5 -X POST "${TG_API_URL}" \
      -d "chat_id=${CHAT_ID}" \
      -d "text=${REG_MSG}" \
      -d "parse_mode=Markdown" > /dev/null
    
    echo "✅ [Agent] 已向司令部发送接入申请，请在 Telegram 手机端完成授权！"
    echo "$AGENT_IP" > "$IP_CACHE"
  else
    echo "ℹ️ [Agent] IP 未变动 ($AGENT_IP)，跳过重复注册申请。"
  fi
fi

# 3. 部署独立 Webhook 脚本（v3.1.0: 移除 heredoc 内联，使用独立 Python 文件）
if [ ! -f "$WEBHOOK_SCRIPT" ]; then
  echo "⚠️ [Agent] webhook.py 不存在，请检查安装完整性。"
  exit 1
fi

# --- [重点升级 3: 真正的静默后台启动] ---
echo "🚀 [Agent] 正在后台启动 Webhook 监听服务 (端口: $AGENT_PORT)..."
nohup python3 "$WEBHOOK_SCRIPT" "$AGENT_PORT" > /dev/null 2>&1 &
disown 2>/dev/null || true
echo "✅ [Agent] 守护进程启动完毕，可安全关闭终端。"
