#!/usr/bin/env bash
# Hily i18n 三语言文件校验脚本
#
# 检查：
#   1. en/ar/tr 三个 Localizable.strings key 集合是否完全一致
#   2. 每个 key 的占位符（%@ / %d）数量和顺序在三语言间是否一致
#   3. L10n.swift 引用的所有 key 是否都在 strings 文件中存在
#
# 退出码：
#   0 = 全部通过
#   1 = 发现问题（详情打印到 stdout）
#
# 用法：bash .claude/skills/i18n/scripts/validate.sh

set -u

# 项目根（脚本位于 .claude/skills/i18n/scripts/，向上 4 级到项目根）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
EN="$ROOT/Sources/en.lproj/Localizable.strings"
AR="$ROOT/Sources/ar.lproj/Localizable.strings"
TR="$ROOT/Sources/tr.lproj/Localizable.strings"
L10N="$ROOT/Sources/L10n.swift"

ERR=0
echo "=== Hily i18n 校验 ==="

# 文件存在
for f in "$EN" "$AR" "$TR" "$L10N"; do
    if [ ! -f "$f" ]; then
        echo "❌ 缺失文件: $f"
        ERR=1
    fi
done
[ $ERR -ne 0 ] && exit 1

# === 检查 1: key 集合对齐 ===
echo ""
echo "[1/3] 三语言 key 集合对齐..."
KEYS_EN=$(grep -oE '^"[^"]+"' "$EN" | sort -u)
KEYS_AR=$(grep -oE '^"[^"]+"' "$AR" | sort -u)
KEYS_TR=$(grep -oE '^"[^"]+"' "$TR" | sort -u)

EN_AR_DIFF=$(diff <(echo "$KEYS_EN") <(echo "$KEYS_AR"))
EN_TR_DIFF=$(diff <(echo "$KEYS_EN") <(echo "$KEYS_TR"))
if [ -n "$EN_AR_DIFF" ]; then
    echo "  ❌ en vs ar key 不一致："
    echo "$EN_AR_DIFF" | sed 's/^/      /'
    ERR=1
fi
if [ -n "$EN_TR_DIFF" ]; then
    echo "  ❌ en vs tr key 不一致："
    echo "$EN_TR_DIFF" | sed 's/^/      /'
    ERR=1
fi
[ -z "$EN_AR_DIFF" ] && [ -z "$EN_TR_DIFF" ] && echo "  ✅ 三语言 key 完全对齐（$(echo "$KEYS_EN" | wc -l | tr -d ' ') keys）"

# === 检查 2: 占位符一致性（数量 + 顺序）===
echo ""
echo "[2/3] 占位符（%@ / %d / %1\$@ 等）一致性..."
MISMATCHES=0
while IFS= read -r key_quoted; do
    [ -z "$key_quoted" ] && continue
    en_holders=$(grep -F "$key_quoted" "$EN" | head -1 | grep -oE '%[0-9$@d]+' | tr '\n' ' ')
    ar_holders=$(grep -F "$key_quoted" "$AR" | head -1 | grep -oE '%[0-9$@d]+' | tr '\n' ' ')
    tr_holders=$(grep -F "$key_quoted" "$TR" | head -1 | grep -oE '%[0-9$@d]+' | tr '\n' ' ')
    if [ "$en_holders" != "$ar_holders" ] || [ "$en_holders" != "$tr_holders" ]; then
        echo "  ❌ $key_quoted: en=[$en_holders] ar=[$ar_holders] tr=[$tr_holders]"
        MISMATCHES=$((MISMATCHES + 1))
        ERR=1
    fi
done <<< "$KEYS_EN"
[ $MISMATCHES -eq 0 ] && echo "  ✅ 所有 key 占位符在三语言间一致"

# === 检查 3: L10n.swift key 是否都在 strings 文件 ===
echo ""
echo "[3/3] L10n.swift 引用的 key 在 strings 文件存在性..."
L10N_KEYS=$(grep -oE 'localize\("[^"]+"' "$L10N" | sed 's/localize("//;s/"$//' | sort -u)
MISSING=0
while IFS= read -r k; do
    [ -z "$k" ] && continue
    if ! grep -qF "\"$k\"" "$EN"; then
        echo "  ❌ L10n.swift 引用 key \"$k\" 但 en.lproj 不存在"
        MISSING=$((MISSING + 1))
        ERR=1
    fi
done <<< "$L10N_KEYS"
[ $MISSING -eq 0 ] && echo "  ✅ L10n.swift 全部 $(echo "$L10N_KEYS" | wc -l | tr -d ' ') 个 key 都在 strings 文件存在"

# === 汇总 ===
echo ""
if [ $ERR -eq 0 ]; then
    echo "=== ✅ 全部通过 ==="
else
    echo "=== ❌ 发现问题，见上方 ==="
fi
exit $ERR
