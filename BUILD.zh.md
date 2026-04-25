# 构建与发布指南

本项目是基于 [opencode](https://github.com/anomalyco/opencode) 的 fork 版本。本文档说明如何构建、发布自己的版本。

## 前置条件

- [Bun](https://bun.sh/) 1.3+
- [Git](https://git-scm.com/)
- Node.js 24+（桌面应用构建需要）
- Rust 工具链（Tauri 桌面应用构建需要，可选）

## 本地开发

```bash
bun install
bun dev          # 启动 TUI
bun dev serve    # 启动 API 服务器
```

### 编译本地二进制

```bash
./packages/opencode/script/build.ts --single
```

编译产物在 `packages/opencode/dist/mycode-<platform>/bin/mycode`

## 发布 Release 版本

### 1. 需要注册的账号

| 平台 | 用途 | 注册地址 |
|------|------|----------|
| **GitHub** | 代码托管、CI/CD、Release 发布 | https://github.com/signup |
| **npm** | 发布 npm 包（支持 `npm i -g` 安装） | https://www.npmjs.com/signup |

> **npm 账号注意**: 如果使用 scoped 包名（如 `@dnasdw/mycode`），需要在 npm 上创建组织或使用个人 scope。注册后运行 `npm login` 登录。

### 2. GitHub 仓库配置

#### 2.1 Fork 并克隆仓库

```bash
git clone https://github.com/<your-username>/opencode.git
cd opencode
```

#### 2.2 分支策略

本项目使用 [restack](./restack/README.zh.md) 工作流维护 fork 分支：以 bridge commit + `git cherry-pick` 替代 history 重写，所有分支引用只通过 fast-forward 前进，永不 force-push。

| 分支 | 角色 |
|------|------|
| `dev` | `upstream/dev` 的同步镜像（由 `restack/03-sync.sh` fast-forward）。**不是堆叠的基分支**，主要用于从中 cherry-pick 提交，作成临时 hotfix 分支 |
| `restack` | 项目工具/脚本特性分支（包含 `restack/` 脚本目录本身），堆叠在上游 release tag（`@base`）之上 |
| `feat/mycode-build` | 构建与发布定制分支（npm 包名、二进制名、CI 配置、命令重命名等基础设施修改），堆叠在 `restack` 之上 |
| `feat/*` | 功能分支，堆叠在 `feat/mycode-build` 之上 |
| `fix/*` | 修复分支，堆叠在 `feat/mycode-build` 之上 |
| `mycode` | 集成分支，通过 `restack/06-stack.sh` 自动生成，不应手动修改 |

**GitHub 默认分支**应为 `mycode`，因为它包含 GitHub Actions 配置（通过堆叠继承）且是最终可发布的分支。

> **升级与堆叠的基是上游 release tag，不是 `dev`。** 例如 `v1.14.18`。`dev` 只是被同步以便 cherry-pick hotfix，不参与堆叠 DAG。

DAG 配置在 `restack/restack.txt` 中（当前检出的分支可能滞后于 `restack` 分支上的最新版本，以 `restack` 分支为准）：

```
@integration mycode
@remote-primary origin
@remote-upstream upstream

@sync dev

restack @base
feat/mycode-build restack
```

常用流程（从仓库根目录运行）：

```bash
# 拉取上游所有 tag（主要是最新 release tag，如 v1.14.18）并 fast-forward dev
restack/03-sync.sh

# 把整条堆叠（restack -> feat/mycode-build）重新 base 到新的 release tag
# <base-sha> 应为上游 release tag 的 commit SHA（bridge + cherry-pick，运行前自动备份）
restack/05-upgrade.sh <base-sha>

# 构建/刷新 mycode 集成分支
restack/06-stack.sh <base-sha>

# 推送所有分支、tag 和 refs/restack/* 到 origin
restack/07-push.sh
```

> 完整脚本说明、配置格式、冲突处理、备份与恢复机制请参阅 [`restack/README.zh.md`](./restack/README.zh.md)。restack 需要在能提供真正 bash 的环境中运行（Git Bash / WSL / MSYS2 / Cygwin），**不要**从 `cmd.exe` 或 PowerShell 直接调用。

#### 2.3 配置 GitHub Actions 所需的 Secrets 和 Variables

进入仓库 **Settings > Secrets and variables > Actions**，配置以下内容：

##### 必需配置

| 名称 | 类型 | 说明 | 如何获取 |
|------|------|------|----------|
| `NPM_TOKEN` | Secret | npm 发布令牌 | 在 npmjs.com > Access Tokens > Generate New Token > 选择 "Automation" 类型 |
| `GITHUB_TOKEN` | （自动） | GitHub 自动提供，无需手动配置 | N/A |

##### 可选配置（用于 Git Committer 身份）

官方使用 GitHub App 来创建 bot commit。个人 fork 可以简化这部分：

**方式一：使用默认 GITHUB_TOKEN（推荐，最简单）**

不需要配置任何额外 Secret。修改 `.github/actions/setup-git-committer/action.yml`，将 GitHub App token 替换为默认的 `GITHUB_TOKEN`。

**方式二：创建 GitHub App（更专业）**

| 名称 | 类型 | 说明 |
|------|------|------|
| `OPENCODE_APP_ID` | Variable | GitHub App ID |
| `OPENCODE_APP_SECRET` | Secret | GitHub App 私钥 |

创建步骤：

1. 进入 GitHub > Settings > Developer settings > GitHub Apps > New GitHub App
2. 设置名称（如 `mycode-bot`）
3. Repository permissions: Contents (Read & Write), Metadata (Read)
4. 创建后生成 Private Key
5. 将 App ID 存为 Variable，Private Key 存为 Secret
6. 在仓库中安装该 App

#### 2.4 npm 发布配置

在项目根目录创建 `.npmrc` 文件（不要提交到 Git）：

```
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

或者确保 CI 环境中 `NODE_AUTH_TOKEN` 环境变量已设置。

对于 scoped 包（如 `@dnasdw/mycode`），默认发布为私有包。要发布为公开包：

- 在 `publish.ts` 中使用 `--access public` 参数（已配置）
- 或在 package.json 中不设置 `"private": true`

### 3. 发布流程

#### 3.1 通过 GitHub Actions 发布（推荐）

**手动触发**：进入 **Actions > publish > Run workflow**，选择分支和版本号递增类型（major/minor/patch）。

**自动触发**：推送代码到 `ci`、`dev`、`beta` 或 `snapshot-*` 分支会自动触发 publish workflow。

> **注意**：建议先用手动触发测试，确认流程无误后再使用自动触发。

#### 3.2 版本号规则

| 场景 | 版本号 | 说明 |
|------|--------|------|
| 手动选择 bump | x.y.z+1 | 根据 major/minor/patch 递增 |
| dev/ci/beta 分支自动 | 0.0.0-<分支名>-YYYYMMDDHHMM | 预览版本，基于分支名和时间戳 |
| 手动指定版本 | 自定义 | workflow_dispatch 中设置 OPENCODE_VERSION |

> **注意**：预览版本（非 `latest` channel）发布到 npm 时会打上分支名对应的 tag（如 `feat/mycode-build`），用户需要 `npm i -g @dnasdw/mycode@feat/mycode-build` 才会安装到，不影响 `@latest`。

#### 3.3 CI/CD 流程概览

```
push to dev/ci/beta/snapshot-*  或  手动 workflow_dispatch
  -> version job（确定版本号，创建 draft release）
    -> build-cli job（编译多平台 CLI 二进制）
    -> build-tauri job（编译桌面应用，可选）
    -> build-electron job（编译 Electron 桌面应用，可选）
      -> publish job（发布到 npm、创建 GitHub Release）
```

### 4. 通过 npm 安装

发布后，用户可以通过以下方式安装：

```bash
# 使用 npm
npm i -g @dnasdw/mycode@latest

# 使用 bun
bun add -g @dnasdw/mycode@latest

# 使用 pnpm
pnpm add -g @dnasdw/mycode@latest
```

安装后直接使用 `mycode` 命令启动。

### 5. 通过 GitHub Release 安装

每个版本会自动在 GitHub Releases 页面发布各平台的二进制文件：

```
mycode-darwin-arm64.zip     # macOS Apple Silicon
mycode-darwin-x64.zip       # macOS Intel
mycode-linux-arm64.tar.gz   # Linux ARM64
mycode-linux-x64.tar.gz     # Linux x64
mycode-windows-arm64.zip    # Windows ARM64
mycode-windows-x64.zip      # Windows x64
```

用户可以手动下载解压使用。

### 6. 桌面应用

> **关于代码签名**: 桌面应用在没有代码签名的情况下可以正常使用，但操作系统会显示安全警告。
>
> - **macOS**: 首次打开需要右键 > 打开
> - **Windows**: 会显示"未知发布者"警告，点击"仍要运行"即可
>
> 如需代码签名：
>
> - Apple Developer Program: $99/年
> - Windows (Azure Trusted Signing): 约 $10/月

#### 签名相关配置（可选）

如需代码签名，需配置以下 Secrets：

| 名称 | 说明 |
|------|------|
| `APPLE_CERTIFICATE` | Apple 开发者证书（base64 编码的 P12 文件） |
| `APPLE_CERTIFICATE_PASSWORD` | P12 文件密码 |
| `APPLE_API_ISSUER` | Apple API Issuer ID |
| `APPLE_API_KEY` | Apple API Key ID |
| `APPLE_API_KEY_PATH` | Apple API Key P8 文件内容 |
| `AZURE_CLIENT_ID` | Azure 客户端 ID（Windows 签名） |
| `AZURE_TENANT_ID` | Azure 租户 ID |
| `AZURE_SUBSCRIPTION_ID` | Azure 订阅 ID |
| `AZURE_TRUSTED_SIGNING_ACCOUNT_NAME` | Azure Trusted Signing 账户名 |
| `AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE` | Azure 签名证书配置文件 |
| `AZURE_TRUSTED_SIGNING_ENDPOINT` | Azure 签名端点 |
| `TAURI_SIGNING_PRIVATE_KEY` | Tauri 更新签名私钥 |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Tauri 签名密码 |

### 7. 与官方 opencode 共存

本 fork 的设计允许与官方 opencode 同时安装：

| 特性 | 官方版 | 本 fork |
|------|--------|---------|
| 命令名 | `opencode` | `mycode` |
| npm 包名 | `opencode-ai` | `@dnasdw/mycode` |
| 配置路径 | `~/.config/opencode` | `~/.config/opencode`（共享） |
| 数据路径 | `~/.local/share/opencode` | `~/.local/share/opencode`（共享） |
| 更新源 | anomalyco/opencode | dnasdw/opencode |

两个版本共享相同的配置和数据目录，但各自独立更新。

### 8. 常见问题

#### Q: npm publish 失败提示 403

A: 检查 NPM_TOKEN 是否正确，以及包名是否已被其他人占用。scoped 包（@username/xxx）不会冲突。

#### Q: GitHub Actions 不触发

A: 检查 workflow 中的 `if: github.repository == 'dnasdw/opencode'` 条件是否匹配你的仓库。

#### Q: 桌面应用构建失败

A: 确保 Runner 上安装了 Rust 工具链和平台相关依赖。macOS 需要 Xcode，Linux 需要 webkit2gtk 等库。

#### Q: 如何修改二进制名或包名

A: 主要修改以下文件：

- `packages/opencode/package.json` - name 和 bin 字段
- `packages/opencode/bin/mycode` - 二进制查找逻辑中的包名前缀
- `packages/opencode/script/build.ts` - 构建输出文件名
- `packages/opencode/script/postinstall.mjs` - 安装后链接的二进制名
- `packages/opencode/script/publish.ts` - npm 发布包名
- `packages/opencode/src/index.ts` - CLI scriptName 和命令帮助检测
- `packages/opencode/src/temporary.ts` - 临时目录名前缀
- `packages/opencode/src/installation/index.ts` - 更新和安装逻辑中的包名和仓库引用
- `packages/opencode/src/cli/cmd/uninstall.ts` - npm 卸载命令中的包名
- `packages/opencode/src/acp/agent.ts` - ACP 认证命令提示
- `packages/opencode/src/mcp/index.ts` - MCP 内置服务器匹配条件
- `packages/opencode/src/cli/cmd/mcp.ts` - MCP 命令提示信息
- `packages/opencode/src/cli/cmd/pr.ts` - PR 导入会话时调用的命令
- `packages/opencode/src/cli/error.ts` - 错误提示中的命令建议
- `packages/opencode/src/provider/error.ts` - Provider 错误提示中的命令建议
- `packages/opencode/src/provider/provider.ts` - Provider 错误提示中的命令建议
- `.github/workflows/publish.yml` - runner 和仓库检查条件

#### Q: npm 发布测试流程

A: 首次发布建议：

1. 用 `--dry-run` 模拟：`npm publish *.tgz --access public --tag test --dry-run`
2. 发布到测试 tag：`npm publish *.tgz --access public --tag test`（不影响 latest）
3. 确认无误后通过 CI 正式发布
4. 72 小时内可撤回：`npm unpublish @dnasdw/mycode@<version>`

#### Q: bun.lock 中出现 npmmirror.com 的 URL

A: `bun.lock` 会被 `bun install` 自动生成，会使用本地 npm registry 配置。如果本地配置了 npmmirror 镜像，锁文件中会出现 `registry.npmmirror.com`。解决方法：

```powershell
# 临时切换到官方 registry
npm config set registry https://registry.npmjs.org/
git checkout dev -- bun.lock
bun install
# 切回镜像（可选）
npm config set registry https://registry.npmmirror.com/
```
