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

## 阶段 2：高风险网络默认值修复

日期：2026-07-05

### 已完成

- 使用主代理 + 2 个子代理完成 `mihomo.sh` 和 `a2up.sh` 安全默认值审查。
- `a2up.sh`
  - 新增 RPC 密钥生成、读取、校验和保留逻辑。
  - aria2 RPC 默认改为 `rpc-listen-all=false`，仅监听本机。
  - `install` / `reconfig` 写入配置时始终写入非空 `rpc-secret`。
  - 扫描服务改用 `0600` 环境文件传递 `ARIA2_RPC_SECRET`，主 aria2 服务不再携带无用密钥环境变量。
  - `info` 输出对 `rpc-secret` 脱敏。
  - `doctor` 增加 RPC 本机监听、密钥和扫描服务环境文件检查。
- `mihomo.sh`
  - 默认 `external-controller` 改为 `127.0.0.1:9090`。
  - 新增管理 `secret` 生成、读取、校验和保留逻辑。
  - 新建默认配置和订阅配置时写入 `secret`，并收紧配置文件权限。
  - 订阅导入/代理组重生成时保留已有 `external-controller` 和 `secret`。
  - `port 8899` / `port :8899` 默认展开为 `127.0.0.1:8899`，显式 `0.0.0.0:9090` 仍允许。
  - 访问信息按实际 controller host 显示，避免本机绑定时误提示服务器 IP。
- README 同步 aria2 RPC 与 Mihomo Web 管理默认安全策略。

### 验证结果

- `bash -n a2up.sh` 通过。
- `bash -n mihomo.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。
- 静态字符串检查确认旧的不安全默认提示不再存在：
  - `rpc-listen-all=true`
  - `RPC 密钥(留空不启用)`
  - `DEFAULT_CONTROLLER="0.0.0.0:9090"`
  - README 中的默认 `0.0.0.0:9090`

### 发现但未完成

- 当前环境仍缺少 `shellcheck` 和 `shfmt`，可选 lint 被跳过。
- 未执行 `install`、`reconfig`、`start`、`scan-run` 或 Mihomo 真实配置测试，避免触发 systemd、安装动作或外部网络下载。
- `mihomo.sh` 不静默迁移已有用户配置中的 `external-controller: 0.0.0.0:9090`，只补齐缺失 `secret`，避免破坏已有远程管理方式。
- `a2up.sh` 仍允许用户显式设置 `RPC_LISTEN_ALL=true` 后重配置，以兼容确实需要远程 RPC 的场景。

## 阶段 3：运行可靠性修复

日期：2026-07-05

### 已完成

- 使用主代理 + 2 个子代理完成 `mount_webdav.sh` 和 `cf.sh` 运行可靠性审查。
- `mount_webdav.sh`
  - 新增以服务运行用户执行命令的 helper。
  - rclone remote 创建、删除、连通性测试和存在性检查统一使用服务运行用户和同一个 `--config`。
  - `detect_rclone_conf_path` 改为以服务运行用户解析配置路径，避免 `sudo/root` 上下文误拿 root 配置。
  - 服务文件写入改为临时文件 + `install -m 0644`，不再用 `bash -c cat >`。
  - 新增 `fusermount3` / `fusermount` 检测，`ExecStop` 和 `stop` 复用同一路径。
- `cf.sh`
  - service 文件写入改为 `run_root tee` 并设置 `0644`，避免非 root 重定向失败。
  - cloudflared 下载新增架构检测，支持 amd64、arm64、arm、386；下载后先执行临时文件 `--version` 验证，再安装到目标路径。
  - 可预测临时文件改用 `mktemp`。
  - YAML 读写增加单引号 quote/unquote，`set-url` 不再使用 sed replacement 拼接用户 URL。
  - `rename` 在删除旧 service 前记录 enabled 状态，避免重命名后误丢开机启用状态。

### 验证结果

- `bash -n mount_webdav.sh` 通过。
- `bash -n cf.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。
- `cf.sh set-url` 无副作用临时目录测试通过，覆盖 `#`、`&`、反斜杠和单引号 URL。

### 发现但未完成

- 当前环境仍缺少 `shellcheck` 和 `shfmt`，可选 lint 被跳过。
- 未执行真实 WebDAV remote 配置、rclone mount、cloudflared 登录、Tunnel 创建或 systemd 启停。
- `cf.sh` 仍保留代理镜像下载列表；后续可考虑允许关闭镜像代理或固定可信下载源。

## 阶段 4 预期

继续处理剩余 P1/P2 可靠性和安全问题：

- `webdav_copyto_relay.sh`
  - 停止任务时确保终止正在运行的 `rclone copyto` 子进程。
  - 远端大小判断改用结构化字节输出，避免解析人类可读文本。
- `cf.sh`
  - 进一步收敛临时文件和配置写入失败时的回滚行为。
- `mihomo.sh`
  - 用 `mktemp` 替换固定 `/tmp` 文件路径。
  - 端口修改和 YAML 写入继续减少 grep/sed 误伤。
