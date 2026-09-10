# 发布流程

1. 同步 `felinics/Memoh` 的 `packages/runtime` 和 `internal/workspace/bridgepb/bridge.proto`，合并定制能力。此仓库的 Runtime 是独立分发副本；变更协议时同步服务端副本并验证兼容性，避免两边单独演进。
2. Pi/Codex 适配器在独立临时 checkout 中合并各自上游，再导入对应 `adapters/`；保留许可证和锁文件，更新 THIRD_PARTY_NOTICES.md 的提交号。
3. 本地按 README 运行类型检查、测试、构建与 `node scripts/package.mjs`。在目标系统验证启动、版本、MCP 调用和停止；macOS 新安装器需要真实 Mac 验收。
4. 提交后等待 CI。创建 `v<版本>` 标签，手动执行 Release workflow。流程上传 Runtime、Pi ACP、Codex ACP 的 `.tgz` 与 SHA256SUMS，生成草稿 Release，供核对后发布。
5. 发布版本使用 Github Release URL 或本地 tgz 安装。保留上一版产物，回退时安装上一版包并重启 Runtime；不要覆盖用户的 `.memoh` 配置。

CI 在 Linux/Windows/macOS 验证 Runtime，并在 Linux 验证适配器。发布不自动连接或更新任何用户设备，也不上传本机凭据。
