#!/usr/bin/env bash
# 一键重生工程：kill Xcode → xcodegen → pod install → sanity check → 打开 workspace
#
# 用途：修复 `No such module 'AgoraRtcKit'` / `Search path XCFrameworkIntermediates not found`
#      等 pbxproj 被 Xcode 覆盖导致 CP phase 丢失的场景（见 .claude/rules/xcodegen-podinstall-binding.md）
#
# 用法：在项目根目录 `./bin/regen.sh`

set -euo pipefail

# 定位项目根（脚本自身 dirname 的上一级）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 关闭 Xcode（若已打开）"
osascript -e 'tell application "Xcode" to quit' 2>/dev/null || true
# 给 Xcode 释放 pbxproj 内存 cache 的时间
sleep 1

echo "==> xcodegen generate"
xcodegen generate

echo "==> pod install"
LANG=en_US.UTF-8 pod install

echo "==> sanity check: [CP] phase 注入"
phase_names=$(grep 'name = "\[CP\]' Hily.xcodeproj/project.pbxproj | sort -u | wc -l | tr -d ' ')
if [ "$phase_names" -lt 2 ]; then
  echo "❌ Hily target 内 [CP] phase 注入不足（unique names=$phase_names，期望 ≥2）"
  echo "   可能是 Xcode 未完全退出（osascript quit 有时不生效）；"
  echo "   请手动 Cmd+Q 退出 Xcode，然后重跑 ./bin/regen.sh"
  exit 1
fi
echo "    ✓ Hily target CP phase = $phase_names"

xcf_count=$(grep -c 'Copy XCFrameworks' Pods/Pods.xcodeproj/project.pbxproj || true)
if [ "$xcf_count" -lt 3 ]; then
  echo "❌ Pods.xcodeproj Copy XCFrameworks phase 不足（count=$xcf_count，期望 ≥3）"
  exit 1
fi
echo "    ✓ Pods Copy XCFrameworks = $xcf_count"

echo "==> 打开 Hily.xcworkspace"
open Hily.xcworkspace

cat <<'EOF'

✅ 工程已重生。Xcode 打开后请注意：
   1. 若弹 "The project has been modified externally" → 选 Revert（不要选 Keep Xcode Version）
   2. 若弹 "Update to recommended settings"           → 点 Cancel / 关掉（永远不点 Update）
   3. Shift+Cmd+K（Clean Build Folder），然后真机 Run

若仍报 `No such module 'AgoraRtcKit'`，尝试删 DerivedData：
   rm -rf ~/Library/Developer/Xcode/DerivedData/Hily-*
EOF
