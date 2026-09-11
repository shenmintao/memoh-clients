# Memoh Clients

Windows、macOS、Linux/NAS 共用的 Memoh Remote Runtime，以及定制 Pi/Codex ACP 适配器。

配套项目：[服务端与网页](https://github.com/shenmintao/memoh) · [Android App](https://github.com/shenmintao/memoh-android)。本项目是社区定制版。

## 功能

- Runtime 上报版本，Windows 托盘与 macOS 菜单栏显示版本。
- Windows 托盘通过设备自己的 Runtime Key 异步查询服务端连接状态；查询失败显示状态未知，不从日志或进程存在推断在线。需要服务端提供 `/runtimes/status` 接口。
- 本机发现 MCP 与 Skills，供绑定的 Bot 按权限调用；Skill 正文按需读取。
- MCP 配置、访问令牌和外部 Agent 登录状态留在运行设备上。
- Pi/Codex ACP 支持 Memoh 运行中补充指令。

## 目录

| 目录 | 用途 |
| --- | --- |
| `packages/runtime` | TypeScript Runtime、CLI、协议及测试 |
| `installers/windows` | PowerShell 安装器、托盘、卸载脚本 |
| `installers/macos` | launchd 安装器、Swift 菜单栏 |
| `installers/linux` | systemd 用户服务，适用于 Linux 与支持 systemd 的 NAS |
| `adapters/pi-acp` | Pi ACP 定制源码，保留 MIT 许可 |
| `adapters/codex-acp` | Codex ACP 定制源码，保留 Apache-2.0 许可 |

## 构建

需要 Node.js 22+、pnpm 10.27.0。根工作区只管理 Runtime，适配器各用自己的 npm 锁文件。

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
cd adapters/pi-acp
npm ci
npm run typecheck && npm test && npm run build
cd ../codex-acp
npm ci
npm run typecheck && npm test && npm run build
cd ../..
node scripts/package.mjs
```

产物在 `artifacts/`。定制包以 GitHub Release 附件分发，保留上游包名以兼容安装路径；包设为 private，发布流程不向上游 npm 命名空间发布。

## 安装

先在自己的 Memoh 网页“电脑 → 连接其他电脑”创建该设备独立的 Runtime Key。下载源码和 Release 的三个 `.tgz` 文件，将它们放在源码根目录 `artifacts/` 下（分别为 `runtime.tgz`、`pi-acp.tgz`、`codex-acp.tgz`）。

Windows（Node.js 22+、PowerShell 7）：

```powershell
./installers/windows/Install-MemohWindows.ps1 -Server https://your-memoh.example/api
```

Linux/NAS（systemd 用户服务）：

```sh
MEMOH_SERVER=https://your-memoh.example/api bash installers/linux/install.sh
```

macOS（需 Xcode Command Line Tools 与 Python 3）：

```sh
MEMOH_SERVER=https://your-memoh.example/api bash installers/macos/install.sh
```

其他 NAS 可安装 `artifacts/runtime.tgz` 后，使用自己的服务管理器运行 `memoh-runtime`；通过进程环境提供 `MEMOH_RUNTIME_SERVER` 和 `MEMOH_RUNTIME_KEY`。不要把 Key 写入仓库或命令行历史。

Windows 使用 DPAPI 保存 Runtime Key；macOS/Linux 配置文件只允许当前用户读取。外部 Agent 首次使用时需在设备上单独完成模型登录。macOS 菜单栏可手动重开，Runtime 本身由 launchd 自动启动。

## 本地能力

- `~/.memoh/mcp.json`：标准 `mcpServers` 配置，支持 stdio、HTTP、SSE。
- `~/.memoh/skills`、`~/.agents/skills`、`~/.pi/agent/skills`：默认 Skill 目录。
- `~/.memoh/capabilities.json`：能力开关和额外 Skill 目录。

仅能在 NAS 访问的服务，应只在 NAS 配置其 MCP 和凭据。手机与网页通过 Memoh 调用该 NAS 的能力。

发布与上游同步见 [RELEASING.md](RELEASING.md)，来源及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
