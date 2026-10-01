#!/bin/sh
#
# dsh-desktop —— 启动 Electron 桌面端（未打包的开发态）
#
# 为什么需要这个脚本
# ------------------
# `dsh desktop` 是**故意封死**的，CLI 会直接报错：
#     error: profile "desktop" is managed exclusively by the Electron application
# 依据 apps/cli/src/args.ts 的 rejectElectronProfile() —— 硬编码拒绝 profile 名 "desktop"。
#
# 所以桌面端只能由 Electron 壳启动，即 apps/desktop 的 pnpm 脚本：
#     pnpm run dev:desktop     构建后启动
#     pnpm run start:desktop   跳过构建，直接启动已有产物
#
# 用法
# ----
#   dsh-desktop                构建 + 启动（等价 pnpm run dev:desktop）
#   dsh-desktop --skip-build   跳过构建直接启动（等价 pnpm run start:desktop）
#   dsh-desktop --isolated     保持 dev 隔离 home（默认是共享产品 home，见下）
#
# DSH_HOME 语义（本脚本最关键的决策）
# -----------------------------------
# 默认 **共享产品 home（~/.dsh）** —— 这样插件、凭证、会话都和打包版一致，
# 才能真正当日常驱动用。dev 模式自己也会写 ~/.dsh/profiles/desktop。
#
# 加 --isolated 则回到 dev 原生行为：DSH_HOME = apps/desktop/.desktop-build/development/home，
# 插件与凭证都隔离，不碰你的真实环境。
#
# 依据 apps/desktop/scripts/dev.ts：
#     const home = resolve(process.env.DSH_HOME ?? join(DEVELOPMENT_ROOT, 'home'))
# 即显式给 DSH_HOME 就会覆盖 dev 的默认隔离。
#
# 注意
# ----
# * Electron 自己的浏览器数据始终隔离在
#   apps/desktop/.desktop-build/development/electron-user-data
#   （除非显式设 DSH_DESKTOP_USER_DATA_DIR）。
# * 首次启动会下载 primary runtime（node + pnpm + python + office），比较慢。
# * 默认会打开 DevTools；关掉用 DSH_DESKTOP_OPEN_DEVTOOLS=0。
# * 调试端口：Main 9229 / Renderer 9222 / Host 9230。
#
# 环境变量
#   DSH_REPO   指定 harness 检出的路径（默认见下）
#
# 安装（本文件通过软链暴露到 PATH，在仓库根目录执行）：
#   ln -sf "$PWD/local/dsh-desktop.sh" ~/.local/bin/dsh-desktop

set -eu

REPO="${DSH_REPO:-/Users/nava/Code/github/deepseek-harness}"

usage() {
  cat <<'EOF'
dsh-desktop —— 启动 Electron 桌面端（未打包的开发态）

用法:
  dsh-desktop                构建 + 启动
  dsh-desktop --skip-build   跳过构建，直接启动已有产物
  dsh-desktop --isolated     使用 dev 隔离 home（默认共享 ~/.dsh）
  dsh-desktop -h             显示本帮助

注意: `dsh desktop` 不可用 —— CLI 硬编码拒绝 profile 名 "desktop"。
EOF
}

SKIP_BUILD=0
ISOLATED=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --isolated)   ISOLATED=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)
      printf 'dsh-desktop: 未知参数 %s（-h 看帮助）\n' "$arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$REPO" ]; then
  printf 'dsh-desktop: 仓库目录不存在：%s\n' "$REPO" >&2
  printf '             用 DSH_REPO=<检出路径> 指定正确位置。\n' >&2
  exit 1
fi

if [ ! -f "$REPO/apps/desktop/package.json" ]; then
  printf 'dsh-desktop: 找不到 desktop 包：%s/apps/desktop\n' "$REPO" >&2
  exit 1
fi

# Electron 二进制优先走国内镜像（见文件头说明）。
# 必须在这里 export：dev.ts 的 require('electron') 会触发安装检查。
: "${ELECTRON_MIRROR:=https://npmmirror.com/mirrors/electron/}"
export ELECTRON_MIRROR
# @electron/get 默认不会主动启用 HTTP_PROXY/HTTPS_PROXY；设为 true 后，
# 镜像不可达时也能使用终端代理。保留用户显式传入的值。
: "${ELECTRON_GET_USE_PROXY:=true}"
export ELECTRON_GET_USE_PROXY

if [ "$ISOLATED" -eq 0 ]; then
  DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
  export DSH_HOME
  printf 'dsh-desktop: DSH_HOME=%s（与打包版共享 profile）\n' "$DSH_HOME"
  if [ ! -f "$DSH_HOME/profiles/desktop/package.json" ]; then
    printf 'dsh-desktop: 提示 —— desktop profile 尚未初始化。\n'
    printf '             桌面端首次启动会自动创建；但如果你打算先跑\n'
    printf '             `dsh plugin --profile desktop add ...`，务必先启动一次桌面端，\n'
    printf '             否则 profile 会被建成「只有 base、没有 web-app」，桌面 UI 起不来。\n'
  fi
else
  printf 'dsh-desktop: 使用 dev 隔离 home（不碰 ~/.dsh）\n'
fi

# WorkBuddy 的非登录 shell 可能没有加载 mise shims，导致裸 `pnpm` 找不到。
# 优先使用当前 PATH 的 pnpm；否则用 Homebrew mise，并显式以仓库为配置根，
# 这样仍然命中 mise.toml 固定的 Node / pnpm 版本。
MISE_BIN=''
PNPM_BIN=''
if command -v pnpm >/dev/null 2>&1; then
  PNPM_BIN=$(command -v pnpm)
elif [ -x /opt/homebrew/bin/mise ]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  printf 'dsh-desktop: 找不到 pnpm，也找不到 /opt/homebrew/bin/mise。\n' >&2
  printf '             请先安装 mise 或在终端加载 mise shims。\n' >&2
  exit 1
fi

if [ "$SKIP_BUILD" -eq 1 ]; then
  if [ -n "$MISE_BIN" ]; then
    exec "$MISE_BIN" -C "$REPO" exec -- pnpm --dir "$REPO" run start:desktop
  fi
  exec "$PNPM_BIN" --dir "$REPO" run start:desktop
fi

if [ -n "$MISE_BIN" ]; then
  exec "$MISE_BIN" -C "$REPO" exec -- pnpm --dir "$REPO" run dev:desktop
fi
exec "$PNPM_BIN" --dir "$REPO" run dev:desktop
