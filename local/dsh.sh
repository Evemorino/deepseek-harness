#!/bin/sh
#
# dsh —— DeepSeek Harness 启动器
#
# 从**任意目录**启动 harness，不必先 cd 进仓库。
#
#   dsh web                      起 Web UI
#   dsh headless "跑个任务"       跑一个任务并打印结果
#   dsh --profile headless ...   显式指定 profile
#   dsh --version
#
# 安装（本文件通过软链暴露到 PATH）：
#   ln -sf "$PWD/scripts/dsh.sh" ~/.local/bin/dsh
#
# 两条必须知道的性质
# ------------------
# 1. 跑的是**构建产物**（apps/cli/lib/bin.js），不是源码。
#    改了仓库源码后需要重新构建才生效： cd "$REPO" && pnpm run build
#    想在仓库内「改完即生效」地调试，仍用： pnpm dsh ...
#
#    注意产物被 .gitignore 忽略，且 apps/cli/tsdown.config.ts 里配了
#    `clean: ['lib/*.js']` —— 每次构建都会先删掉再重建。所以「产物暂时不存在」
#    是构建过程中的正常中间态，而不是异常。本脚本对它给出明确提示，
#    而不是丢一句 no such file or directory。
#
# 2. **工作区（workspace root）＝ 执行命令时所在的目录**。
#    这是 dsh 的官方语义（apps/cli/README.md：
#    "The invoking directory is the default workspace root"）。
#    → 在哪个项目目录下敲 dsh，它就操作哪个项目。
#
# 环境变量
#   DSH_REPO   指定 harness 检出的路径（默认见下）
#
# 个性化配置在 ~/.dsh/ 下，与本脚本无关：
#   ~/.dsh/cordis.patch.yml    home 级 patch 层（所有 profile 共享，优先级最高）
#   ~/.dsh/profiles/<name>/    各 profile
#   ~/.dsh/.credentials.yaml   凭证

set -eu

REPO="${DSH_REPO:-/Users/nava/Code/github/deepseek-harness}"
BIN="$REPO/apps/cli/lib/bin.js"

if [ ! -f "$BIN" ]; then
  {
    printf 'dsh: 找不到构建产物\n'
    printf '     期望路径：%s\n' "$BIN"
    if [ -d "$REPO" ]; then
      printf '     仓库在，但产物缺失 —— 请先构建：\n'
      printf '       cd %s && pnpm run build\n' "$REPO"
    else
      printf '     仓库目录不存在：%s\n' "$REPO"
      printf '     用 DSH_REPO=<检出路径> 指定正确位置。\n'
    fi
  } >&2
  exit 1
fi

exec node "$BIN" "$@"
