# 开发进度

## 阶段 1：工程化基线与安全基线

日期：2026-07-05

### 已完成

- 使用主代理 + 2 个子代理完成首轮基线审查。
- 将 `scripts/validate.sh` 改为动态发现 `.sh` 文件，避免新增脚本漏检。
- 增加 `make help`、`make lint`、`make format`，统一开发入口。
- 增加 `.pre-commit-config.yaml`，本地提交钩子复用 `make validate`。
- 修复 `webdav_copyto_relay.sh` 配置文件保存后未收紧权限的问题。
- 修复 `webdav_copyto_relay.sh` 状态文件直接 `source` 的风险，改为安全 key-value 解析和百分号编码。
- 修复 `napcat.sh` shebang 不在第一行的问题。
- README 增加开发与校验说明，明确优先复用 `shellcheck`、`shfmt`、`pre-commit`、`bats-core`、`yq` 等成熟方案。

### 验证结果

- `make validate` 通过。
- `bash -n` 覆盖：
  - `a2up.sh`
  - `astr.sh`
  - `cf.sh`
  - `mihomo.sh`
  - `mount_webdav.sh`
  - `napcat.sh`
  - `scripts/validate.sh`
  - `webdav_copyto_relay.sh`
- 当前环境未安装 `shellcheck` 和 `shfmt`，可选 lint 被跳过。

### 发现但未完成

- 当前 Termux/Android 文件系统拒绝 `chmod 755 *.sh scripts/*.sh`，返回 `Operation not permitted`。后续如果迁移到普通 Linux 文件系统，应统一修正脚本工作区权限。
- `mihomo.sh` 默认暴露管理端口和未设置 secret 的问题需要单独阶段处理。
- `a2up.sh` aria2 RPC 默认可监听所有地址且 secret 可为空，需要单独阶段处理。
- `mount_webdav.sh` 以 sudo/root 配置 rclone remote 与 systemd 运行用户不一致的问题需要单独阶段处理。
- `cf.sh` systemd service 写入、URL sed 转义、架构检测和临时文件安全需要单独阶段处理。
- `webdav_copyto_relay.sh` 停止任务时未确保终止 rclone 子进程，远端大小判断也需要改用结构化输出。

### 复用方案

- 静态检查：`shellcheck`
- 格式化：`shfmt`
- 本地钩子：`pre-commit`
- Bash 回归测试：`bats-core`
- YAML 结构化编辑：`yq`

## 阶段 2 预期

优先处理高风险运行默认值和运行时行为问题：

- 收敛 `mihomo.sh` 默认监听地址，生成或要求管理 secret。
- 收敛 `a2up.sh` aria2 RPC 默认监听地址，生成或要求 RPC secret。
- 为上述改动补最小无副作用验证路径。
