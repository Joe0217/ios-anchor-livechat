#!/usr/bin/env bash
# 切换 iOS 构建环境（Debug configFile）+ 触发 regen.sh 重生工程
#
# 用法: ./bin/switch-env.sh <dev|test|prod>
#
# 说明:
#   - 修改 project.yml 里 configFiles.Debug 一行指向目标 xcconfig
#   - 自动跑 ./bin/regen.sh：关 Xcode → xcodegen → pod install → sanity → open workspace
#   - Release 一直绑 Config-Prod（archive 上线用），不受本脚本影响
#
# 环境对照:
#   dev   → Config/Config-Dev.xcconfig   (anchor.cphub.link / 独立 dev 密钥)
#   test  → Config/Config-Test.xcconfig  (anchorpre.cphub.link / prod SDK 密钥集群)
#   prod  → Config/Config-Prod.xcconfig  (anchor.hnhily.link / prod SDK 密钥集群)

set -euo pipefail

usage() {
  # 打印首行 shebang 之后的注释块（第一个非注释行前停止）
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
  exit 1
}

[ $# -eq 1 ] || usage

case "$1" in
  dev)  TARGET_NAME="Dev";  HOST_HINT="anchor.cphub.link";     KEYS_HINT="dev 独立密钥" ;;
  test) TARGET_NAME="Test"; HOST_HINT="anchorpre.cphub.link";  KEYS_HINT="prod SDK 密钥集群（Test 后端 + Prod 云信/声网）" ;;
  prod) TARGET_NAME="Prod"; HOST_HINT="anchor.hnhily.link";    KEYS_HINT="prod SDK 密钥集群" ;;
  -h|--help) usage ;;
  *)    echo "❌ 未知环境: $1"; echo ""; usage ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCCONFIG="Config/Config-${TARGET_NAME}.xcconfig"
if [ ! -f "$XCCONFIG" ]; then
  echo "❌ 目标 xcconfig 不存在: $XCCONFIG"
  echo ""
  echo "   test/prod 密钥不入库（见 .gitignore）；如首次拉代码，请从模板 cp 一份并按真实密钥填:"
  echo "     cp Config/Config-Dev.xcconfig $XCCONFIG"
  echo "     # 然后按 anchor-livechat-h5/.env.${1} 里的 VITE_* 逐项替换 HOST / AES / NIM / Agora 值"
  exit 2
fi

CURRENT=$(grep -E "^      Debug: Config/Config-.*\.xcconfig$" project.yml | sed 's|.*Config/Config-||;s|\.xcconfig||' || true)
if [ -z "$CURRENT" ]; then
  echo "❌ project.yml 未找到 Debug configFile 行，请手动检查"
  exit 3
fi

if [ "$CURRENT" = "$TARGET_NAME" ]; then
  echo "ℹ️  Debug 已绑 Config-${TARGET_NAME}.xcconfig，跳过 project.yml 修改"
  echo "   继续跑 regen.sh 确保工程文件与 project.yml 一致..."
else
  echo "==> project.yml: Debug configFile ${CURRENT} → ${TARGET_NAME}"
  # BSD sed (macOS): -i '' 表示原地改无备份后缀
  sed -i '' "s|      Debug: Config/Config-.*\.xcconfig|      Debug: Config/Config-${TARGET_NAME}.xcconfig|" project.yml
  if ! grep -q "^      Debug: Config/Config-${TARGET_NAME}.xcconfig$" project.yml; then
    echo "❌ sed 未命中，请手动检查 project.yml 第 54 行左右"
    exit 4
  fi
  echo "    ✓ 已切"
fi

cat <<EOF

🎯 目标环境: ${1}
   API host : ${HOST_HINT}
   密钥集群 : ${KEYS_HINT}

EOF

exec ./bin/regen.sh
