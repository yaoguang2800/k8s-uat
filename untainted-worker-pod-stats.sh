#!/bin/bash
# untainted-worker-pod-stats.sh
# 用法:
#   bash untainted-worker-pod-stats.sh              # 终端输出 + 飞书推送
#   DRY_RUN=true bash untainted-worker-pod-stats.sh # 只终端输出，不推送

set -euo pipefail

FEISHU_WEBHOOK="${FEISHU_WEBHOOK:-https://open.feishu.cn/open-apis/bot/v2/hook/b35bc582-9b34-4db4-b570-114dafbac896}"
DRY_RUN="${DRY_RUN:-false}"

echo "=============================================="
echo "  无污点 Worker 节点 Pod 密度明细"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="
echo ""

# ============================================================
# 1. 获取所有节点，过滤出"无污点"的 worker 节点
# ============================================================

# 方法：kubectl get nodes -o json，用 jq 过滤
# 条件：
#   - 不是 master/control-plane（没有对应 label）
#   - spec.taints 为空 或 不存在（真正的无污点节点）

mapfile -t UNTAINTED_NODES < <(kubectl get nodes -o json | jq -r '
  .items[] |
  select(
    # 排除 master / control-plane
    (.metadata.labels["node-role.kubernetes.io/master"] == null) and
    (.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
  ) |
  select(
    # 无污点：taints 为 null 或空数组
    (.spec.taints == null or (.spec.taints | length == 0))
  ) |
  .metadata.name
')

TOTAL=${#UNTAINTED_NODES[@]}
echo "📌 无污点 Worker 节点数: $TOTAL"
echo ""

if [[ $TOTAL -eq 0 ]]; then
  echo "❌ 未找到无污点 worker 节点，退出"
  exit 1
fi

# ============================================================
# 2. 逐节点统计 max-pods / 实际 Pod 数 / 密度
# ============================================================

declare -a NODE_NAMES
declare -a MAX_PODS_ARR
declare -a POD_COUNTS
declare -a DENSITY_ARR

TOTAL_CAPACITY=0
TOTAL_PODS=0
MAX110_COUNT=0
MAX150_COUNT=0
OTHER_COUNT=0

for node in "${UNTAINTED_NODES[@]}"; do
  # max-pods
  max_pods=$(kubectl get node "$node" -o jsonpath='{.status.capacity.pods}' 2>/dev/null || echo "0")
  max_pods=${max_pods//\"/}

  # 实际 Pod 数（排除 Succeeded/Failed）
  pod_count=$(kubectl get pods --all-namespaces \
    --field-selector="spec.nodeName=$node,status.phase!=Succeeded,status.phase!=Failed" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$max_pods" -gt 0 ]]; then
    pct=$((pod_count * 100 / max_pods))
  else
    pct=0
  fi

  NODE_NAMES+=("$node")
  MAX_PODS_ARR+=("$max_pods")
  POD_COUNTS+=("$pod_count")
  DENSITY_ARR+=("$pct")

  TOTAL_CAPACITY=$((TOTAL_CAPACITY + max_pods))
  TOTAL_PODS=$((TOTAL_PODS + pod_count))

  case "$max_pods" in
    110) MAX110_COUNT=$((MAX110_COUNT + 1)) ;;
    150) MAX150_COUNT=$((MAX150_COUNT + 1)) ;;
    *)   OTHER_COUNT=$((OTHER_COUNT + 1)) ;;
  esac
done

OVERALL_PCT=0
if [[ $TOTAL_CAPACITY -gt 0 ]]; then
  OVERALL_PCT=$((TOTAL_PODS * 100 / TOTAL_CAPACITY))
fi

# ============================================================
# 3. 终端表格输出
# ============================================================

printf "%-28s %8s %10s %10s %s\n" "NODE" "MAX" "CURRENT" "DENSITY" "BAR"
printf "%-28s %8s %10s %10s %s\n" "----" "---" "-------" "-------" "---"

for i in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[$i]}"
  mp="${MAX_PODS_ARR[$i]}"
  pc="${POD_COUNTS[$i]}"
  pct="${DENSITY_ARR[$i]}"

  bar_len=$((pct / 5))
  bar=$(printf "%${bar_len}s" | tr ' ' '█')

  # 颜色标记
  color=""
  reset=""
  if [[ "$pct" -ge 90 ]]; then
    color="🔴"
  elif [[ "$pct" -ge 80 ]]; then
    color="🟡"
  elif [[ "$pct" -ge 60 ]]; then
    color="🟢"
  else
    color="⚪"
  fi

  printf "%-2s %-26s %8s %10s %8s%% %s\n" "$color" "$node" "$mp" "$pc" "$pct" "$bar"
done

echo ""
echo "=============================================="
echo "  📋 汇总"
echo "=============================================="
printf "  无污点 Worker 节点数:  %d\n" "$TOTAL"
printf "  max-pods=110:         %d 个\n" "$MAX110_COUNT"
printf "  max-pods=150:         %d 个\n" "$MAX150_COUNT"
if [[ "$OTHER_COUNT" -gt 0 ]]; then
  printf "  其他 max-pods:         %d 个\n" "$OTHER_COUNT"
fi
printf "  总容量 (Pod):          %d\n" "$TOTAL_CAPACITY"
printf "  实际总副本数 (Pod):    %d\n" "$TOTAL_PODS"
printf "  整体密度:              %d%%\n" "$OVERALL_PCT"
echo ""

# 告警
HIGH_COUNT=0
for pct in "${DENSITY_ARR[@]}"; do
  if [[ "$pct" -ge 80 ]]; then
    HIGH_COUNT=$((HIGH_COUNT + 1))
  fi
done
if [[ "$HIGH_COUNT" -gt 0 ]]; then
  echo "  ⚠️  $HIGH_COUNT 个节点密度 ≥ 80%（需关注）"
else
  echo "  ✅ 无节点达到 80% 密度"
fi

# ============================================================
# 4. 飞书推送
# ============================================================

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  (DRY_RUN=true, 跳过飞书推送)"
  exit 0
fi

# 构建表格内容（取 TOP 20 热点）
TABLE_ROWS=""
count=0
for i in "${!NODE_NAMES[@]}"; do
  [[ $count -ge 20 ]] && break
  node="${NODE_NAMES[$i]}"
  mp="${MAX_PODS_ARR[$i]}"
  pc="${POD_COUNTS[$i]}"
  pct="${DENSITY_ARR[$i]}"

  # 按密度排序（简单冒泡，节点数不多性能OK）
  for j in "${!NODE_NAMES[@]}"; do :; done

  TABLE_ROWS="${TABLE_ROWS}\n| ${node} | ${mp} | ${pc} | ${pct}% |"
  count=$((count + 1))
done

# 按密度排序（用 sort）
SORTED_TABLE=$(for i in "${!NODE_NAMES[@]}"; do
  echo "${DENSITY_ARR[$i]}%|${NODE_NAMES[$i]}|${MAX_PODS_ARR[$i]}|${POD_COUNTS[$i]}|${DENSITY_ARR[$i]}"
done | sort -rn | head -20 | while IFS='|' read -r _ n m p pt; do
  echo "| $n | $m | $p | $pt% |"
done)

# 确定 header 颜色
HEADER_COLOR="green"
ALERT_TEXT="✅ 集群密度正常"
if [[ "$OVERALL_PCT" -ge 80 ]]; then
  HEADER_COLOR="red"
  ALERT_TEXT="🔴 整体密度 ≥80%，请立即处理"
elif [[ "$OVERALL_PCT" -ge 60 ]]; then
  HEADER_COLOR="orange"
  ALERT_TEXT="🟡 整体密度 ≥60%，建议关注"
fi

# 构建飞书 markdown 内容
MD_CONTENT="## 🖥️ 无污点 Worker 节点 Pod 密度报告
> 📅 $(date '+%Y-%m-%d %H:%M') | 无污点节点: **${TOTAL}** | 整体密度: **${OVERALL_PCT}%**

### 📊 容量汇总
| 指标 | 数值 |
|------|------|
| 无污点 Worker 节点 | **${TOTAL}** (110节点:${MAX110_COUNT}, 150节点:${MAX150_COUNT}) |
| 总容量 | **${TOTAL_CAPACITY}** |
| 实际总副本数 | **${TOTAL_PODS}** |
| 整体密度 | **${OVERALL_PCT}%** |

### ⚠️ 告警
- ${ALERT_TEXT}
- 密度 ≥80% 的节点: **${HIGH_COUNT}** 个

### 🔥 TOP 20 热点节点
| 节点 | max-pods | 实际副本 | 密度 |
|------|----------|----------|------|
$(echo "$SORTED_TABLE")

---
💡 数据来源: \`kubectl get nodes/pods\` | 排除所有有污点节点（含VM/管控/特殊域）"

# 飞书 payload
PAYLOAD=$(cat <<EOF
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {
        "tag": "plain_text",
        "content": "🖥️ 无污点 Worker Pod 密度报告 [${OVERALL_PCT}%]"
      },
      "template": "${HEADER_COLOR}"
    },
    "elements": [
      {
        "tag": "markdown",
        "content": $(echo "$MD_CONTENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
      }
    ]
  }
}
EOF
)

HTTP_CODE=$(curl -s -o /tmp/feishu_resp.json -w "%{http_code}" -X POST "$FEISHU_WEBHOOK" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo ""
  echo "  ✅ 飞书推送成功"
else
  echo ""
  echo "  ❌ 飞书推送失败 (HTTP $HTTP_CODE)"
  cat /tmp/feishu_resp.json 2>/dev/null || true
fi
