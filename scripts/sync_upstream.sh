#!/usr/bin/env bash
# 一键从上游 kolbicz/WQFiles 同步最新提交并运行构建验证
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

UPSTREAM_URL="https://github.com/kolbicz/WQFiles.git"
if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
fi

echo "==> 正在获取上游最新代码 ($UPSTREAM_URL)..."
git fetch --no-tags upstream main

if git merge-base --is-ancestor upstream/main HEAD; then
    echo "✓ 当前已是最新状态（已包含上游提交 $(git rev-parse --short upstream/main)）。"
    exit 0
fi

echo "==> 发现上游新提交："
git log HEAD..upstream/main --oneline --no-decorate
echo ""

BASE_SHA=$(git merge-base HEAD upstream/main)
echo "==> 尝试三路合并 upstream/main..."
git merge --no-commit --no-ff upstream/main || true
# 自动保留本仓库的中文文档与软件源配置，避免上游改文档引发无关冲突
git checkout --ours -- README.md source.json 2>/dev/null || true
git add README.md source.json

REMAINING_CONFLICTS=$(git diff --name-only --diff-filter=U || true)
if [[ -z "$REMAINING_CONFLICTS" ]]; then
    echo "✓ 代码合并无冲突！"
    echo ""
    echo "==> 上游本次新增的字符串字面量预览（如有新增英文 UI 可在此处顺手汉化）："
    git diff "$BASE_SHA..upstream/main" -- '*.m' '*.h' | grep -E '^\+.*@"[A-Za-z]' | head -n 30 || echo "（无新增英文字符串）"
    echo ""
    echo "==> 正在运行测试套件并重新构建 WQFiles.ipa..."
    ./build.sh
    VERSION=$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)
    BUILD=$(plutil -extract CFBundleVersion raw -o - Info.plist)
    python3 scripts/update_source.py "$VERSION" "$BUILD" WQFiles.ipa
    echo ""
    echo "✓ 同步构建完成！检查无误后可执行 git add -A && git commit 提交。"
else
    echo ""
    echo "⚠ 检测到上游修改了已汉化的代码行，以下文件存在合并冲突："
    git diff --name-only --diff-filter=U
    echo ""
    echo "提示：可直接让 AI 助手处理冲突并自动汉化上游新增内容，完成后运行 ./build.sh 验证。"
    exit 1
fi
