#!/usr/bin/env bash
#
# dsh-sync — 让本地 deepseek-harness 检出与上游保持同步
#
# 设计前提：把「上游源码」和「你的个性化」分到两条分支上，互不打架
#
#   mirror 分支 (默认 master)   = 上游的纯镜像。永不在此提交，只允许快进。
#   work   分支 (默认 personal) = 你的个性化分支。所有改动都落在这里。
#
# 这样每次同步就是：mirror 快进 -> work 合并。mirror 永远干净，
# 冲突只会出现在 work 分支上，而且范围可控。
#
# 用法:
#   dsh-sync status            查看本地状态（不联网）
#   dsh-sync check             拉取远端并报告是否有更新
#   dsh-sync sync              拉取远端更新并合并进 work 分支
#   dsh-sync setup             初始化 upstream 远端与 mirror/work 分支结构
#   dsh-sync help              显示帮助
#
# 常用参数:
#   -C, --repo <path>          指定仓库路径（默认用当前目录）
#   -n, --dry-run              只报告要做什么，不改动任何东西
#       --leave-conflicts      合并冲突时保留现场，交给你手工解决
#       --stash                工作区脏时自动 stash / stash pop
#       --upstream-url <url>   setup 时用的官方仓库地址
#   -q, --quiet                安静模式（只输出结论行）
#       --json                 机器可读输出（给自动化用）
#
# 退出码:
#   0   成功 / 已是最新
#   1   出错
#   2   sync 时留下了未解决的冲突
#   10  check 时发现上游有更新（供自动化判断用）
#
# 环境变量覆盖:
#   DSH_SYNC_REPO       仓库路径
#   DSH_UPSTREAM_REMOTE 上游远端名（默认 upstream，缺失时回退 origin）
#   DSH_UPSTREAM_BRANCH 上游分支名（默认 master）
#   DSH_MIRROR_BRANCH   镜像分支名（默认 master）
#   DSH_WORK_BRANCH     个性化分支名（默认 personal）
#

set -euo pipefail

# ---------------------------------------------------------------- 输出 helpers

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

QUIET=0
JSON=0
log()  { if [ "$QUIET" = 0 ] && [ "$JSON" = 0 ]; then printf '%s\n' "$*"; fi; }
info() { log "${C_BLU}▸${C_RST} $*"; }
ok()   { log "${C_GRN}✓${C_RST} $*"; }
warn() { if [ "$JSON" = 0 ]; then printf '%s\n' "${C_YEL}!${C_RST} $*" >&2; fi; }
die()  { printf '%s\n' "${C_RED}✗ $*${C_RST}" >&2; exit 1; }

# ---------------------------------------------------------------- 参数解析

CMD=""
REPO="${DSH_SYNC_REPO:-}"
DRY_RUN=0
LEAVE_CONFLICTS=0
AUTO_STASH=0
UPSTREAM_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    status|check|sync|setup) CMD="$1"; shift ;;
    help|-h|--help)          CMD="help"; shift ;;
    -C|--repo)               REPO="${2:-}"; [ -n "$REPO" ] || die "--repo 需要一个路径"; shift 2 ;;
    -n|--dry-run)            DRY_RUN=1; shift ;;
    --leave-conflicts)       LEAVE_CONFLICTS=1; shift ;;
    --stash)                 AUTO_STASH=1; shift ;;
    --upstream-url)          UPSTREAM_URL="${2:-}"; [ -n "$UPSTREAM_URL" ] || die "--upstream-url 需要一个 URL"; shift 2 ;;
    -q|--quiet)              QUIET=1; shift ;;
    --json)                  JSON=1; QUIET=1; shift ;;
    *) die "未知参数: $1（试试 dsh-sync help）" ;;
  esac
done

[ -n "$CMD" ] || CMD="help"

if [ "$CMD" = "help" ]; then
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
  exit 0
fi

# ---------------------------------------------------------------- 基础工具

branch_exists()  { git rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }
current_branch() { git symbolic-ref --quiet --short HEAD 2>/dev/null || echo ""; }
is_dirty()       { [ -n "$(git status --porcelain)" ]; }

# work 分支是否还没包含 mirror 分支的提交（= 还有待合并的上游提交）
# 必须单独判断：上次合并冲突回滚后 mirror 已快进，若只看 mirror 位置
# 就会误判「已是最新」，work 分支永远合不上。
work_lags_mirror() {
  if ! branch_exists "$WORK_BRANCH"; then return 1; fi
  if [ "$WORK_BRANCH" = "$MIRROR_BRANCH" ]; then return 1; fi
  if git merge-base --is-ancestor "$MIRROR_BRANCH" "$WORK_BRANCH" 2>/dev/null; then
    return 1
  fi
  return 0
}

# 输出 "behind<TAB>ahead"（相对 $UPSTREAM_REF）
# git rev-list --left-right --count A...B 的左数=A独有(=ahead)，右数=B独有(=behind)
counts_vs_upstream() {
  local ref="${1:-HEAD}"
  git rev-list --left-right --count "$ref...$UPSTREAM_REF" 2>/dev/null \
    | awk '{ print $2 "\t" $1 }' \
    || printf '0\t0'
}

# ---------------------------------------------------------------- 探测

resolve_repo() {
  if [ -n "$REPO" ]; then
    cd "$REPO" 2>/dev/null || die "仓库路径不存在: $REPO"
  fi
  git rev-parse --git-dir >/dev/null 2>&1 || die "当前目录不是 git 仓库（用 -C 指定路径）"
  REPO="$(git rev-parse --show-toplevel)"
}

resolve_remotes() {
  UPSTREAM_REMOTE="${DSH_UPSTREAM_REMOTE:-upstream}"
  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    # 没配 upstream 就退回 origin（即直接 clone 官方仓、没做 fork 的用法）
    UPSTREAM_REMOTE="origin"
  fi
  UPSTREAM_BRANCH="${DSH_UPSTREAM_BRANCH:-master}"
  MIRROR_BRANCH="${DSH_MIRROR_BRANCH:-master}"
  WORK_BRANCH="${DSH_WORK_BRANCH:-personal}"
  UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

  git rev-parse --verify --quiet "refs/remotes/$UPSTREAM_REF" >/dev/null \
    || die "找不到远端分支 ${UPSTREAM_REF}（先跑 dsh-sync setup，或 git fetch ${UPSTREAM_REMOTE}）"
}

fetch_upstream() {
  info "拉取 $UPSTREAM_REMOTE ..."
  git fetch --tags --prune "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
    || die "git fetch 失败（检查网络 / SSH key）"
}

# ---------------------------------------------------------------- status

cmd_status() {
  resolve_repo
  resolve_remotes

  local br counts behind ahead dirty=0
  br="$(current_branch)"
  if is_dirty; then dirty=1; fi
  counts="$(counts_vs_upstream HEAD)"
  behind="${counts%%$'\t'*}"
  ahead="${counts##*$'\t'}"

  if [ "$JSON" = 1 ]; then
    printf '{"repo":"%s","branch":"%s","dirty":%s,"behind":%s,"ahead":%s,"upstream":"%s","mirror_branch":"%s","work_branch":"%s"}\n' \
      "$REPO" "$br" "$([ "$dirty" = 1 ] && echo true || echo false)" \
      "$behind" "$ahead" "$UPSTREAM_REF" "$MIRROR_BRANCH" "$WORK_BRANCH"
    return 0
  fi

  local mirror_note="" work_note=""
  if [ "$MIRROR_BRANCH" = "$br" ]; then mirror_note=" ${C_DIM}(当前)${C_RST}"; fi
  if branch_exists "$WORK_BRANCH"; then work_note="${C_GRN}存在${C_RST}"; else work_note="${C_DIM}尚未创建${C_RST}"; fi

  log "${C_BLD}仓库${C_RST}       $REPO"
  log "${C_BLD}当前分支${C_RST}   $br"
  log "${C_BLD}上游${C_RST}       $UPSTREAM_REF"
  log "${C_BLD}镜像分支${C_RST}   $MIRROR_BRANCH$mirror_note"
  log "${C_BLD}个性化分支${C_RST} $WORK_BRANCH ($work_note)"
  if [ "$dirty" = 1 ]; then
    log "${C_BLD}工作区${C_RST}     ${C_YEL}有未提交改动${C_RST}"
  else
    log "${C_BLD}工作区${C_RST}     ${C_GRN}干净${C_RST}"
  fi
  local pending=0
  if work_lags_mirror; then pending=1; fi

  log "${C_BLD}落后上游${C_RST}   $behind 个提交"
  log "${C_BLD}领先上游${C_RST}   $ahead 个提交"
  if [ "$pending" = 1 ]; then
    log "${C_BLD}待合并${C_RST}     ${C_YEL}$WORK_BRANCH 尚未包含 $MIRROR_BRANCH 的提交${C_RST}"
  fi
  log ""

  if [ "$behind" = "0" ] && [ "$pending" = 0 ]; then
    ok "已与上游同步"
  elif [ "$behind" != "0" ]; then
    info "上游有 $behind 个新提交，跑 dsh-sync sync 拉进来"
  else
    info "$WORK_BRANCH 还有未合并的上游提交，跑 dsh-sync sync 完成合并"
  fi
}

# ---------------------------------------------------------------- check

cmd_check() {
  resolve_repo
  resolve_remotes
  fetch_upstream

  local counts behind ahead
  counts="$(counts_vs_upstream "$MIRROR_BRANCH")"
  behind="${counts%%$'\t'*}"
  ahead="${counts##*$'\t'}"

  if [ "$JSON" = 1 ]; then
    printf '{"updates":%s,"behind":%s,"ahead":%s,"upstream":"%s"}\n' \
      "$([ "$behind" != "0" ] && echo true || echo false)" "$behind" "$ahead" "$UPSTREAM_REF"
  elif [ "$behind" = "0" ]; then
    ok "已是最新（$MIRROR_BRANCH 与 $UPSTREAM_REF 一致）"
  else
    info "上游有 ${C_BLD}$behind${C_RST} 个新提交可拉取"
    git --no-pager log --oneline "$MIRROR_BRANCH..$UPSTREAM_REF" 2>/dev/null \
      | head -10 | sed 's/^/    /' || true
  fi

  if [ "$behind" != "0" ]; then
    return 10
  fi
  return 0
}

# ---------------------------------------------------------------- sync

cmd_sync() {
  resolve_repo
  resolve_remotes

  local counts behind
  counts="$(counts_vs_upstream "$MIRROR_BRANCH")"
  behind="${counts%%$'\t'*}"

  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 会执行：git fetch --tags --prune $UPSTREAM_REMOTE"
  else
    fetch_upstream
  fi

  counts="$(counts_vs_upstream "$MIRROR_BRANCH")"
  behind="${counts%%$'\t'*}"

  local pending=0
  if work_lags_mirror; then pending=1; fi

  if [ "$behind" = "0" ] && [ "$pending" = 0 ]; then
    ok "已是最新，无需同步"
    return 0
  fi
  if [ "$behind" != "0" ]; then
    info "上游领先 $behind 个提交，开始同步"
  else
    info "${WORK_BRANCH} 还没合并 ${MIRROR_BRANCH} 上的提交，继续同步"
  fi

  # --- 脏工作区处理
  local stashed=0
  if is_dirty; then
    if [ "$AUTO_STASH" = 1 ] && [ "$DRY_RUN" = 0 ]; then
      info "工作区有未提交改动，自动 stash"
      git stash push -u -m "dsh-sync auto-stash $(date +%Y%m%d-%H%M%S)" >/dev/null
      stashed=1
    else
      die "工作区有未提交改动。先提交/丢弃，或加 --stash 自动暂存"
    fi
  fi

  local orig_branch rc=0
  orig_branch="$(current_branch)"

  # --- 1) mirror 分支快进
  if branch_exists "$MIRROR_BRANCH"; then
    if [ "$DRY_RUN" = 1 ]; then
      info "[dry-run] 切到 $MIRROR_BRANCH 并快进到 $UPSTREAM_REF"
    else
      git checkout --quiet "$MIRROR_BRANCH"
      if git merge --ff-only --quiet "$UPSTREAM_REF" >/dev/null 2>&1; then
        ok "$MIRROR_BRANCH 快进完成 -> $(git rev-parse --short HEAD)"
      else
        die "$MIRROR_BRANCH 无法快进（可能有人在此提交过）。镜像分支必须保持纯净。"
      fi
    fi
  fi

  # --- 2) work 分支
  if ! branch_exists "$WORK_BRANCH"; then
    if [ "$DRY_RUN" = 1 ]; then
      info "[dry-run] 创建 ${WORK_BRANCH}（基于 ${MIRROR_BRANCH}）"
    else
      git checkout --quiet -b "$WORK_BRANCH" "$MIRROR_BRANCH"
      ok "已创建个性化分支 $WORK_BRANCH"
    fi
  elif [ "$WORK_BRANCH" != "$MIRROR_BRANCH" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "[dry-run] 切到 $WORK_BRANCH 并合并 $UPSTREAM_REF"
    else
      git checkout --quiet "$WORK_BRANCH"
      if git merge --no-edit --quiet "$UPSTREAM_REF" >/dev/null 2>&1; then
        ok "$WORK_BRANCH 合并完成 -> $(git rev-parse --short HEAD)"
      else
        local conflicted
        conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
        if [ "$LEAVE_CONFLICTS" = 1 ]; then
          warn "合并 $UPSTREAM_REF 到 $WORK_BRANCH 时发生冲突，已保留现场"
          log ""
          log "  冲突文件："
          printf '%s\n' "$conflicted" | sed 's/^/    /'
          log ""
          log "  解决后：  git add <文件> && git commit"
          log "  放弃合并：git merge --abort"
          rc=2
        else
          git merge --abort >/dev/null 2>&1 || true
          warn "合并 $UPSTREAM_REF 到 $WORK_BRANCH 时发生冲突，已回滚本次合并"
          log ""
          log "  会冲突的文件："
          printf '%s\n' "$conflicted" | sed 's/^/    /'
          log ""
          log "  想手工解决就重跑：dsh-sync sync --leave-conflicts"
          rc=1
        fi
      fi
    fi
  fi

  # --- 3) 回到原来的分支
  if [ "$rc" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -n "$orig_branch" ] \
     && [ "$orig_branch" != "$(current_branch)" ] && [ "$orig_branch" != "$MIRROR_BRANCH" ]; then
    git checkout --quiet "$orig_branch" 2>/dev/null || true
  fi

  # --- 4) 恢复 stash
  if [ "$stashed" = 1 ] && [ "$rc" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    if git stash pop --quiet >/dev/null 2>&1; then
      ok "已恢复自动暂存的改动"
    else
      warn "stash pop 有冲突，改动仍在 stash 里：git stash list"
      rc=1
    fi
  fi

  # --- 5) 依赖变化提示
  if [ "$rc" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    if git diff --name-only "$MIRROR_BRANCH~$behind" "$MIRROR_BRANCH" 2>/dev/null \
       | grep -qE '^(pnpm-lock\.yaml|package\.json|pnpm-workspace\.yaml)$'; then
      warn "依赖清单有变化，建议跑一次 pnpm install"
    fi
  fi

  return $rc
}

# ---------------------------------------------------------------- setup

cmd_setup() {
  resolve_repo

  local official="${UPSTREAM_URL:-git@github.com:deepseek-ai/deepseek-harness.git}"
  UPSTREAM_REMOTE="${DSH_UPSTREAM_REMOTE:-upstream}"
  UPSTREAM_BRANCH="${DSH_UPSTREAM_BRANCH:-master}"
  MIRROR_BRANCH="${DSH_MIRROR_BRANCH:-master}"
  WORK_BRANCH="${DSH_WORK_BRANCH:-personal}"

  log "${C_BLD}仓库${C_RST}  $REPO"
  log ""

  # 1) upstream 远端
  if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    ok "远端 $UPSTREAM_REMOTE 已存在: $(git remote get-url "$UPSTREAM_REMOTE")"
  elif [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] git remote add $UPSTREAM_REMOTE $official"
  else
    git remote add "$UPSTREAM_REMOTE" "$official"
    ok "已添加远端 $UPSTREAM_REMOTE -> $official"
  fi

  # 2) 拉取
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] git fetch --tags --prune $UPSTREAM_REMOTE"
  else
    fetch_upstream
  fi

  local UREF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  local cur; cur="$(current_branch)"

  # 3) mirror 分支
  if branch_exists "$MIRROR_BRANCH"; then
    if [ "$cur" = "$MIRROR_BRANCH" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] git merge --ff-only $UREF"
      elif git merge --ff-only --quiet "$UREF" >/dev/null 2>&1; then
        ok "$MIRROR_BRANCH 已快进到 $UREF"
      else
        die "$MIRROR_BRANCH 无法快进，可能已有本地提交。请先处理。"
      fi
    elif [ "$DRY_RUN" = 1 ]; then
      info "[dry-run] git branch -f $MIRROR_BRANCH $UREF"
    else
      git branch -f "$MIRROR_BRANCH" "$UREF"
      ok "$MIRROR_BRANCH 已重置到 $UREF"
    fi
  elif [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] git branch $MIRROR_BRANCH $UREF"
  else
    git branch "$MIRROR_BRANCH" "$UREF"
    ok "已创建镜像分支 $MIRROR_BRANCH -> $UREF"
  fi

  # 4) 让 mirror 分支跟踪官方（便于 git status 提示）
  if [ "$DRY_RUN" = 0 ]; then
    git branch --set-upstream-to="$UREF" "$MIRROR_BRANCH" >/dev/null 2>&1 || true
  fi

  # 5) work 分支
  if branch_exists "$WORK_BRANCH"; then
    ok "个性化分支 $WORK_BRANCH 已存在，保持不动"
  elif [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] git branch $WORK_BRANCH $MIRROR_BRANCH"
  else
    git branch "$WORK_BRANCH" "$MIRROR_BRANCH"
    ok "已创建个性化分支 ${WORK_BRANCH}（基于 ${MIRROR_BRANCH}）"
  fi

  log ""
  log "${C_BLD}接下来${C_RST}"
  log "$(printf '  %-28s # %s' "git checkout $WORK_BRANCH" "切到你的分支开始改")"
  log "$(printf '  %-28s # %s' "dsh-sync sync" "之后每次同步上游")"
  log "$(printf '  %-28s # %s' "pnpm install" "上游依赖变过，装一次")"
  log ""
  log "${C_DIM}提示：改动尽量放进 ~/.dsh/（harness home），那里天然不受上游影响。${C_RST}"
}

# ---------------------------------------------------------------- main

case "$CMD" in
  status) cmd_status ;;
  check)  cmd_check ;;
  sync)   cmd_sync ;;
  setup)  cmd_setup ;;
  *)      die "未知子命令: $CMD" ;;
esac
