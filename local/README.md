# local/ — 本机个性化脚本

DeepSeek Harness 的**个性化胶水层**，放在上游仓库的 `personal` 分支里。

## 为什么放这里，而不是仓库外另开一个仓库

这里曾是一个独立的 `~/Code/github/dsh-personal/` 仓库（与上游同层级并列）。
现已收进上游仓库的 `personal` 分支，理由：

1. **`personal` 分支的设计意图正是装这类改动** —— 上游给 fork 预留了个性化分支，
   在仓库外再开一个并列目录，等于把「个性化」这件事拆成两个互不知情的地方。
2. **同步器不会被自己绊倒** —— `dsh-sync` 的操作对象是本仓库。`local/` 在 `personal`
   分支上，`master` 分支是上游纯镜像，两边天然隔离；而在仓库外另开目录，
   每次同步都要额外操心「那个目录会不会被误碰」。
3. **一个 clone 就是全部** —— 换机器只 `git clone` 一次，脚本、README、上游源码都在。

`local/` 目录上游**没有**（是 `personal` 分支独有的），所以永远不与上游冲突。
上游新增文件若与 `local/` 撞名（目前无此风险），冲突也只在 `personal` 分支内解决。

## 内容

| 文件 | 作用 |
|---|---|
| `local/dsh.sh` | 启动器。从任意目录启动 harness（`dsh web` / `dsh headless "..."`） |
| `local/dsh-desktop.sh` | 桌面端启动器。起 Electron 壳（`dsh-desktop`） |
| `local/dsh-sync.sh` | 同步器。让本地 deepseek-harness 检出与上游保持同步 |

三个脚本都通过 `~/.local/bin/` 下的**软链**暴露到 PATH：

```
~/.local/bin/dsh          -> <repo>/local/dsh.sh
~/.local/bin/dsh-desktop  -> <repo>/local/dsh-desktop.sh
~/.local/bin/dsh-sync     -> <repo>/local/dsh-sync.sh
```

其中 `<repo>` = `/Users/nava/Code/github/deepseek-harness`。

## 安装（换机器时）

```sh
git clone <repo-url> ~/Code/github/deepseek-harness
cd ~/Code/github/deepseek-harness
git checkout personal          # 个性化脚本在 personal 分支上

ln -sf "$PWD/local/dsh.sh"         ~/.local/bin/dsh
ln -sf "$PWD/local/dsh-desktop.sh" ~/.local/bin/dsh-desktop
ln -sf "$PWD/local/dsh-sync.sh"    ~/.local/bin/dsh-sync
```

`~/.local/bin` 需在 PATH 中 —— 本机由 `~/.path.zsh` 提供。

## 个性化该放哪（优先顺序）

一共四层，**优先用靠前的**：

1. **`~/.dsh/` harness home** —— 不进任何 git，永不冲突，**且跨 profile 共享**：
   - `cordis.patch.yml` —— home 级 patch 层，在所有 bundle 之后叠加，优先级最高
   - `skills/` —— home 级 skill，与 profile 名无关
   - `.env`、`.credentials.yaml`、`sessions/`、`storages/`
2. 🔑 **`~/.dsh/profiles/node_modules/`** —— **全部 profile 共用的包解析层**。
   自研 bundle 装这里 + 在 home patch 里 `insert` → **web / desktop / headless / sdk / acp
   一次全生效**。（依据 `packages/boot/app-boot/src/profile-resolution/resolver.ts`：
   *"The interception layer of a profile is `<profileParent>/node_modules`"*）
3. **`dsh plugin --profile <name> add <pkg|git-spec>`** —— 装 out-of-tree bundle，
   但**只对该 profile 生效**，要多个 surface 用就得多装几次。
4. **本仓库 `personal` 分支** —— 只有真要改上游源码逻辑时才动。

**`local/` 是第 0 层**：连 `~/.dsh/` 都不适合放的「本机可执行工具」。

## 三个启动器的注意点

### `dsh.sh`

1. 它启动的是**构建产物**（`apps/cli/lib/bin.js`），**不是源码**。
   改了上游源码后需要 `cd $REPO && pnpm run build` 才生效；
   想在仓库内「改完即生效」地调试，仍用 `pnpm dsh ...`。
   产物缺失时脚本会提示先跑 `pnpm run build`
   （依据 `apps/cli/tsdown.config.ts` 的 `clean: ['lib/*.js']`，每次构建先删后建）。
2. **工作区（workspace root）＝ 执行 `dsh` 时所在的目录** —— 这是 dsh 的官方语义。
   在哪个项目目录下敲 `dsh`，它就操作哪个项目。

环境变量 `DSH_REPO` 可覆盖默认检出路径（默认 `/Users/nava/Code/github/deepseek-harness`）。

⚠️ 脚本用 PATH 里的 `node`（本机是 mise 提供的）。**在仓库外执行时，mise 取的是全局
node 而非仓库 `mise.toml` 里 pin 的那个** —— 当前两者都是 v24.19.0，无差异；
若将来 pin 值跳变，记得核对。不要改成 `cd "$REPO" && mise exec`：那会改变 cwd，
破坏上面第 2 条「工作区＝调用目录」的语义。要用就用 `mise -C "$REPO" exec`。

### `dsh-desktop.sh`

```sh
dsh-desktop                 # 构建 + 启动（= pnpm run dev:desktop）
dsh-desktop --skip-build    # 跳过构建直接启动（= pnpm run start:desktop）
dsh-desktop --isolated      # 用 dev 隔离 home，不碰 ~/.dsh
```

🔴 **`dsh desktop` 是不可用的** —— CLI 会直接报
`error: profile "desktop" is managed exclusively by the Electron application`。
这是硬编码的（`apps/cli/src/args.ts` 的 `rejectElectronProfile()`），
桌面端只能由 Electron 壳启动。所以才需要这个启动器。

**默认共享产品 home（`~/.dsh`）** —— 这样插件、凭证、会话都和打包版一致，
才能真正当日常驱动用（依据 `apps/desktop/scripts/dev.ts`：
`const home = resolve(process.env.DSH_HOME ?? join(DEVELOPMENT_ROOT, 'home'))`）。
加 `--isolated` 回到 dev 原生隔离。

⚠️ **顺序陷阱**：如果你想先跑 `dsh plugin --profile desktop add ...` 再启动桌面端 —— 别这样。
`PROFILE_TEMPLATES` 里没有 `desktop` 这个模板，CLI 会回退到
`DEFAULT_PROFILE_BUNDLES = ['@deepseek-ai/dsh-base']`，把 profile 建成「只有 base、
没有 `dsh-web-app`」；而 `initProfile` 的规则是「已存在的文件永不触碰」，桌面端后来也不会补上
→ 桌面 UI 起不来。**先启动一次桌面端**再装插件。

#### 这个启动器替你处理的两件事

**① Electron 二进制走国内镜像 + 强制启用代理**

`electron` 包的 postinstall 会从 **GitHub Releases** 下载 ~110MB 二进制。
这条链路默认**不读** `HTTPS_PROXY`/`HTTP_PROXY` —— `@electron/get` 只在
`ELECTRON_GET_USE_PROXY` 为真时才 `initializeProxy()`。只配了终端代理是不够的。

所以脚本在启动前 `export`：

```sh
: "${ELECTRON_MIRROR:=https://npmmirror.com/mirrors/electron/}"
export ELECTRON_MIRROR
: "${ELECTRON_GET_USE_PROXY:=true}"
export ELECTRON_GET_USE_PROXY
```

用 `:=` 保留你自己显式传入的值。必须在这里 export ——
`dev.ts` 的 `require('electron')` 会触发安装检查，晚于脚本入口就来不及了。

**② `pnpm` 找不到时回退到 mise**

WorkBuddy / 非登录 shell 里 mise shims 常常没加载，`pnpm` 不在 PATH。
脚本会回退到 `/opt/homebrew/bin/mise -C "$REPO" exec -- pnpm ...`。

其他：Electron 浏览器数据始终隔离在
`apps/desktop/.desktop-build/development/electron-user-data`；
首次启动要下载 primary runtime（node + pnpm + python + office），比较慢；
默认开 DevTools（`DSH_DESKTOP_OPEN_DEVTOOLS=0` 关）；
调试端口 Main 9229 / Renderer 9222 / Host 9230。

📌 **构建成功 ≠ 桌面出现 app**：`dsh-desktop` 是**开发态**，产物是临时 app
`apps/desktop/.desktop-build/development/Harness Dev.app`，**不会**进 `/Applications`。
要真正的 `.app`/`.dmg` 得走打包（macOS 有签名硬门槛，见仓库 `apps/desktop/.env.macos.example`），
或直接装官方包 `https://download.deepseek.com/desktop/dsh-latest-macos-arm64.dmg`。

### `dsh-sync.sh`

见文件头部注释。子命令 `status` / `check` / `sync` / `setup`；
`check` 发现上游有更新时退出码 10，`sync` 留下未解决冲突时退出码 2。
仓库路径默认取**当前目录**（或用 `-C <path>` / `DSH_SYNC_REPO` 指定）。

同步结构：`origin` → fork（推送目标），`upstream` → 官方（只读真相源）；
`master` = 上游纯镜像（只快进，**永不在此提交**），`personal` = 个性化分支（所有改动落这里）。
