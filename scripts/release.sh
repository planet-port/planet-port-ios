#!/usr/bin/env bash
# 发版脚本：git-cliff 计算版本 → 生成 CHANGELOG → 同步 Info.plist → 提交并打 tag。
# 用法：./scripts/release.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v git-cliff >/dev/null 2>&1 || {
    echo "错误：未安装 git-cliff，请先执行 brew install git-cliff" >&2
    exit 1
}

# 已跟踪文件必须无改动，避免把无关改动卷进发版提交（未跟踪文件不阻塞）
git diff --quiet && git diff --cached --quiet || {
    echo "错误：已跟踪文件有未提交改动，请先提交或暂存" >&2
    exit 1
}

# 从上次 tag 之后的 Conventional Commits 推导下一版本
NEXT=$(git-cliff --bumped-version | tr -d '[:space:]')
case "$NEXT" in
    v*.*) NEXT=${NEXT#v} ;;
    *) echo "错误：无法计算下一版本（自上次 tag 后可能没有新提交）" >&2; exit 1 ;;
esac

# 无新提交时 git-cliff 会原样返回当前版本，防重复发版
LATEST=$(git describe --tags --abbrev=0 | tr -d '[:space:]' | sed 's/^v//')
if [ "$NEXT" = "$LATEST" ]; then
    echo "错误：自 v$LATEST 后没有可触发版本变动的提交" >&2
    exit 1
fi

echo "下一版本：v$NEXT"

# 生成中文更新日志（chore 类提交不入日志）
git-cliff --bump -o CHANGELOG.md

# 同步两个 Info.plist：版本号 + 递增 build 号
PLISTS=(PlanetPort/Info.plist PlanetPortTunnel/Info.plist)
BUILD=1
for plist in "${PLISTS[@]}"; do
    CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
    if [ "$CUR" -ge "$BUILD" ]; then BUILD=$((CUR + 1)); fi
done
for plist in "${PLISTS[@]}"; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"
done

git add CHANGELOG.md "${PLISTS[@]}"
git commit -m "chore(release): v$NEXT" -m "由 scripts/release.sh 生成，版本与更新日志依据 Conventional Commits 自动推导。"
git tag "v$NEXT"

echo "完成：v$NEXT (build $BUILD) 已提交并打 tag。推送到远端时记得：git push --follow-tags"
