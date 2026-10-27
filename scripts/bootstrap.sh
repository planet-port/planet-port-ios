#!/usr/bin/env bash
# 拉取 ZeroTier 核心源码并生成 Xcode 工程（新克隆后执行一次即可）。
#
# 用法：
#   ./scripts/bootstrap.sh
#
# 网络不畅时：
#   1. 换镜像：ZT_TARBALL_URL=<镜像地址> ./scripts/bootstrap.sh
#   2. 完全手动：浏览器下载 tarball 放到缓存目录（默认 ~/Library/Caches/PlanetPort/
#      ZeroTierOne-<版本>.tar.gz，可用 ZT_CACHE_DIR 改位置）后重跑本脚本，
#      校验通过则离线使用。
#
# 升级 ZeroTier 版本：修改下方 ZT_VERSION 与 ZT_SHA256 两个变量后重跑。
# 注意：codeload 自动生成的 tarball 字节不承诺长期稳定（GitHub 曾调整过压缩参数），
# 若某天官方 URL 校验失败，人工核对上游内容后再更新 ZT_SHA256。
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZT_VERSION=1.16.2
ZT_SHA256=2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0
ZT_URL="https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/${ZT_VERSION}"

CACHE_DIR="${ZT_CACHE_DIR:-$HOME/Library/Caches/PlanetPort}"
TARBALL="${CACHE_DIR}/ZeroTierOne-${ZT_VERSION}.tar.gz"
CORE_DIR=Core
STAMP="${CORE_DIR}/.fetched-tag"

err() { echo "错误：$*" >&2; exit 1; }

verify_tarball() {
    echo "${ZT_SHA256}  ${TARBALL}" | shasum -a 256 --check - >/dev/null 2>&1
}

# ---- 拉取 ZeroTier 核心（已就绪则跳过） ----
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$ZT_VERSION" ]]; then
    echo "Core ${ZT_VERSION} 已就绪，跳过拉取"
else
    mkdir -p "$CACHE_DIR"

    # 缓存损坏则清除重下
    if [[ -s "$TARBALL" ]] && ! verify_tarball; then
        echo "缓存 tarball 校验失败，清除后重新下载"
        rm -f "$TARBALL"
    fi

    if [[ ! -s "$TARBALL" ]]; then
        echo "下载 ZeroTierOne ${ZT_VERSION} ..."
        curl -fL --retry 3 --connect-timeout 10 -o "$TARBALL" "${ZT_TARBALL_URL:-$ZT_URL}" || {
            rm -f "$TARBALL"
            err "下载失败。可用镜像：ZT_TARBALL_URL=<镜像地址> ./scripts/bootstrap.sh；或手动下载 tarball 放到 ${TARBALL} 后重跑"
        }
    fi

    verify_tarball || err "SHA256 校验失败（可能被镜像篡改或下载不完整），已保留缓存供排查：${TARBALL}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    tar -xzf "$TARBALL" -C "$TMP"
    SRC="${TMP}/ZeroTierOne-${ZT_VERSION}"

    # 只取工程所需子集：node/include 整目录，osdep 仅跨平台头与工具，
    # ext 仅 nlohmann/json.hpp 与 prometheus-cpp-lite 头文件（拍平上游 include/ 布局）
    rm -rf "$CORE_DIR"
    mkdir -p "$CORE_DIR"
    cp -R "$SRC/node" "$SRC/include" "$CORE_DIR/"
    mkdir -p "$CORE_DIR/osdep"
    for f in Binder.hpp BlockingQueue.hpp ExtOsdep.hpp OSUtils.cpp OSUtils.hpp Phy.hpp; do
        cp "$SRC/osdep/$f" "$CORE_DIR/osdep/"
    done
    cp "$SRC/version.h" "$CORE_DIR/"
    mkdir -p "$CORE_DIR/ext/nlohmann" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/core" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/simpleapi"
    cp "$SRC/ext/nlohmann/json.hpp" "$CORE_DIR/ext/nlohmann/"
    cp -R "$SRC/ext/prometheus-cpp-lite-1.0/core/include/prometheus" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/core/"
    cp -R "$SRC/ext/prometheus-cpp-lite-1.0/simpleapi/include/prometheus" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/simpleapi/"

    echo "$ZT_VERSION" > "$STAMP"
    echo "Core ${ZT_VERSION} 就绪"
fi

# ---- 生成 Xcode 工程 ----
command -v xcodegen >/dev/null 2>&1 || err "缺少 xcodegen，请先执行 brew install xcodegen"
xcodegen generate

# xcodegen 会按 project.yml 的占位版本(1.0.0/1)重写 Info.plist，
# 冲掉 release.sh 写入的发版号——生成后从 git HEAD 恢复，避免重跑 bootstrap 降级版本
for plist in PlanetPort/Info.plist PlanetPortTunnel/Info.plist; do
    [[ -f "$plist" ]] || continue
    tmp="$(mktemp)"
    if git show "HEAD:$plist" > "$tmp" 2>/dev/null; then
        ver="$(plutil -extract CFBundleShortVersionString raw -o - "$tmp" 2>/dev/null || true)"
        build="$(plutil -extract CFBundleVersion raw -o - "$tmp" 2>/dev/null || true)"
        [[ -n "$ver" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" "$plist"
        [[ -n "$build" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    fi
    rm -f "$tmp"
done
