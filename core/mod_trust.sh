#!/bin/bash

# ==========================================================
# 脚本名称: mod_trust.sh (IP 信用净化模块 V2.0 数据解耦版)
# 核心功能: 动态读取云端/本地 JSON 规则池，模拟访问高权重网站稀释恶意流量
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
UA_FILE="${INSTALL_DIR}/data/user_agents.txt"
# [v3.0.2移除] 不再硬编码私库地址，改为从 config.conf 读取 REPO_RAW_URL

# 1. 基础环境校验
[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

# [v3.0.2新增] 从 config.conf 读取 REPO_RAW_URL，兜底使用 GitHub 官方地址
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/sure155/IP-Sentinel/main}"

REGION=${REGION_CODE:-"US"}
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# [v3.0.2修复] 支持 v3.0 三级目录路径，同时兼容旧版单级路径
# 优先使用三级路径: data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json
if [ -n "$COUNTRY_ID" ] && [ -n "$STATE_ID" ] && [ -n "$CITY_ID" ]; then
 REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
else
 REGION_JSON_FILE=""
fi
# 旧版兼容路径: data/regions/${REGION}.json
REGION_JSON_FILE_OLD="${INSTALL_DIR}/data/regions/${REGION}.json"

# 确定最终使用的 JSON 文件 (三级路径优先，不存在则回退旧版)
if [ -n "$REGION_JSON_FILE" ] && [ -f "$REGION_JSON_FILE" ]; then
 : # 三级路径存在，直接使用
elif [ -f "$REGION_JSON_FILE_OLD" ]; then
 REGION_JSON_FILE="$REGION_JSON_FILE_OLD"
fi

# 2. 动态获取配置 (解耦核心)
# 兼容旧节点：如果本地没有 json，自动拉取最新的云端配置 (强制遵循锚点协议)
if [ ! -f "$REGION_JSON_FILE" ]; then
 # [v3.0.2修复] 优先尝试三级路径下载，失败后回退旧版单级路径
 if [ -n "$COUNTRY_ID" ] && [ -n "$STATE_ID" ] && [ -n "$CITY_ID" ]; then
 mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
 curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
 if [ -s "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" ]; then
 REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
 fi
 fi
 # 如果三级路径拉取失败，回退旧版单级路径
 if [ ! -f "$REGION_JSON_FILE" ] || [ ! -s "$REGION_JSON_FILE" ]; then
 mkdir -p "${INSTALL_DIR}/data/regions"
 curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/regions/${REGION}.json" -o "$REGION_JSON_FILE_OLD"
 if [ -s "$REGION_JSON_FILE_OLD" ]; then
 REGION_JSON_FILE="$REGION_JSON_FILE_OLD"
 fi
 fi
fi

# 使用 jq 将 json 中的网址数组安全地读入 Bash 数组
if [ -f "$REGION_JSON_FILE" ]; then
    mapfile -t TRUST_URLS < <(jq -r '.trust_module.white_urls[]' "$REGION_JSON_FILE" 2>/dev/null)
fi

# 兜底：如果仓库挂了或者解析失败，提供国际通用白名单
if [ ${#TRUST_URLS[@]} -eq 0 ]; then
    TRUST_URLS=("https://en.wikipedia.org/wiki/Special:Random" "https://www.apple.com/" "https://www.microsoft.com/")
fi

# 3. 日志规范化
log_msg() {
    local TYPE=$1
    local MSG=$2
    local TIME=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIME] [$TYPE] [Trust  ] [$REGION] $MSG" | tee -a "$LOG_FILE"
}

# 4. 锁定单次会话指纹
if [ -f "$UA_FILE" ]; then
    CURRENT_UA=$(shuf -n 1 "$UA_FILE")
else
    CURRENT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
fi

# ==========================================
# 🚀 净化行动开始
# ==========================================
log_msg "START" "========== 启动区域 IP 信用净化会话 =========="
log_msg "INFO " "已载入 [${REGION}] 区域白名单，配置库条目: ${#TRUST_URLS[@]} 个"
log_msg "INFO " "已锁定本地伪装指纹: $(echo $CURRENT_UA | cut -d' ' -f1-2)..."

STEP_COUNT=$((RANDOM % 4 + 3))
SUCCESS_INJECT=0

for ((i=1; i<=STEP_COUNT; i++)); do
    # 随机抽取本地区域权威网址
    TARGET_URL=${TRUST_URLS[$RANDOM % ${#TRUST_URLS[@]}]}
    
    # [v3.0.1修复] 注入高权重流量时，强制从绑定的 IPv4 或 IPv6 隧道出网
    HTTP_CODE=$(curl -${IP_PREF:-4} -A "$CURRENT_UA" \
        -H "Accept: text/html,application/xhtml+xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Sec-Fetch-Dest: document" \
        -H "Sec-Fetch-Mode: navigate" \
        -H "Upgrade-Insecure-Requests: 1" \
        --compressed \
        -s -o /dev/null -w "%{http_code}" -m 15 "$TARGET_URL")

    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        log_msg "EXEC " "动作[$i/$STEP_COUNT]完成 | 状态: $HTTP_CODE | 注入: $TARGET_URL"
        ((SUCCESS_INJECT++))
    else
        log_msg "EXEC " "动作[$i/$STEP_COUNT]异常 | 状态: $HTTP_CODE | 阻拦: $TARGET_URL"
    fi

    if [ $i -lt $STEP_COUNT ]; then
        SLEEP_TIME=$((RANDOM % 76 + 45))
        log_msg "WAIT " "正在浏览本地高权重页面，模拟停留 $SLEEP_TIME 秒..."
        sleep $SLEEP_TIME
    fi
done

# ==========================================
# 📊 结论判定与输出
# ==========================================
if [ "$SUCCESS_INJECT" -ge $((STEP_COUNT / 2)) ]; then
    log_msg "SCORE" "自检结论: ✅ 信用净化完成 (已成功注入 $SUCCESS_INJECT 条无害流量)"
else
    log_msg "SCORE" "自检结论: ❌ 净化受阻 (部分站点拦截或网络超时)"
fi

log_msg "END  " "========== 会话结束，释放进程 =========="
log_msg "INFO " "系统级调度完毕，信任因子持续积累中..."