#!/usr/bin/env bash

set -euo pipefail

CAPTURE_DIR="$(mktemp -d /tmp/headroom-m0-captures.XXXXXX)"
COUNTDOWN_SECONDS=5

capture_screen() {
  local label="$1"
  local filename="$2"

  printf '\n准备截取：%s\n' "${label}"
  printf '按回车开始倒计时，然后在 %d 秒内打开并保持对应界面。\n' "${COUNTDOWN_SECONDS}"
  read -r

  local remaining
  for ((remaining = COUNTDOWN_SECONDS; remaining > 0; remaining--)); do
    printf '\r%2d 秒后截图… ' "${remaining}"
    sleep 1
  done
  printf '\r正在截图……   \n'
  /usr/sbin/screencapture -x "${CAPTURE_DIR}/${filename}"
  printf '已保存：%s\n' "${CAPTURE_DIR}/${filename}"
  printf '关闭当前界面并回到终端，再继续下一项。\n'
}

cat <<'EOF'
Headroom M0 基线截图

每一项先按回车，再在 5 秒内打开对应界面并保持不动。
脚本截取整个屏幕，后续由 Codex 检查并裁出最终基线。
截图时不要显示 API Key、Cookie、Token 或其他凭据。
EOF

capture_screen "官方账号卡（卡片完整可见）" "official-account-card-full-screen.png"
capture_screen "API 卡（卡片完整可见）" "api-card-full-screen.png"
capture_screen "菜单栏弹层（顶部和底部完整可见）" "status-menu-full-screen.png"
capture_screen "设置页（完整窗口和标题栏可见）" "settings-full-screen.png"

printf '\n四张原始截图已完成。\n目录：%s\n' "${CAPTURE_DIR}"
printf '把上面的目录路径发给 Codex；不要手动移动或重命名文件。\n'
