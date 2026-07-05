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

## 阶段 4：剩余可靠性和临时文件修复

日期：2026-07-05

### 已完成

- 使用主代理 + 2 个子代理完成 `webdav_copyto_relay.sh` 和 `mihomo.sh` 剩余风险审查。
- `webdav_copyto_relay.sh`
  - 新增当前 `rclone copyto` 子进程 PID 记录。
  - `stop` 和任务 `INT/TERM` trap 会先终止正在运行的 `rclone copyto`，再停止后台 worker。
  - PID 文件读取增加正整数校验，任务 PID 清理改为匹配当前 worker 后再删除，降低重启竞态风险。
  - 统计状态文件改为同目录临时文件 + `mv` 原子替换。
  - 远端大小判断改为优先读取 `rclone size --json` 的 `bytes`，并回退到 `rclone lsjson --stat` 的 `Size`，避免解析人类可读大小。
  - `status` 对数值字段增加兜底，避免损坏或半写入状态导致算术错误。
  - 后台启动关闭 stdin，并将 stderr 追加到日志。
- `mihomo.sh`
  - 固定 `/tmp/mihomo.gz`、`/tmp/metacubexd.tgz`、`/tmp/zashboard.zip`、`/tmp/mihomo_test.log` 改为 `mktemp` 私有临时路径。
  - 订阅导入不再写入固定 `$SUB_FILE.tmp`，改为同目录 `mktemp` 文件验证后替换。
  - 新增顶层 YAML scalar 读取/写入 helper，`secret`、`external-controller`、`port`、`socks-port` 修改统一走同一路径。
  - SOCKS5 自动块删除改为精确 marker 处理，缺失 END marker 时保留原内容，避免误删到 EOF。
  - SOCKS5 块插入和 listeners 检测收敛到顶层 `rules:` / `listeners:`，降低嵌套 key 误判。

### 验证结果

- `bash -n webdav_copyto_relay.sh` 通过。
- `bash -n mihomo.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。
- 静态检查确认 `mihomo.sh` 不再包含以下固定临时路径或文件：
  - `/tmp/mihomo`
  - `/tmp/metacubexd`
  - `/tmp/zashboard`
  - `/tmp/mihomo_test`
  - `SUB_FILE.tmp`
- 无副作用临时 copy 测试通过：
  - `mihomo.sh` 的 `change_http_port`、`change_socks_port`、`change_controller_port` 会正确更新顶层 key。
  - fake `rclone` 同大小远端文件走 skip，不触发 `copyto`。
  - fake `rclone copyto` 睡眠任务被 `stop` 正确终止，`task.pid` 和 `rclone.pid` 被清理。

### 发现但未完成

- 当前环境仍缺少 `shellcheck` 和 `shfmt`，可选 lint 被跳过。
- 未执行真实 Mihomo 安装、配置测试、重启、rclone WebDAV 传输或外部网络下载。
- `webdav_copyto_relay.sh` 的 JSON 字段解析仍保持无新增依赖实现；后续如允许引入成熟工具，可优先接入可选 `jq`。
- `cf.sh` 配置写入失败回滚尚未处理，建议放入阶段 5。

## 阶段 5：本地写入回滚和回归测试沉淀

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `cf.sh`、`mihomo.sh` 和 `webdav_copyto_relay.sh` 测试沉淀审查。
- `cf.sh`
  - service 文件写入改为同目录临时文件 + `mv` 原子替换，不再直接 `tee` 到最终文件。
  - yml 写入补充显式失败清理和返回值，便于上层捕获。
  - 新增本地 yml/service bundle 写入 helper：写入前备份旧文件，任一写入失败则恢复旧 yml/service；原先不存在的文件会删除。
  - `create`、`sync`、`rename` 改用 bundle 写入，避免 yml 成功但 service 失败时留下半更新状态。
  - `rename` 改为新本地文件写入成功后再删除旧本地文件，降低远端 rename 后本地断裂风险。
  - `delete` 改为远程删除成功后再删除本地 yml/service/credentials，远程失败时保留本地配置便于重试。
  - `set-url`、`repair` 显式检查配置写入失败并报错。
- `mihomo.sh`
  - 新增可选 YAML 工具探测：优先识别 Mike Farah `yq` v4。
  - 顶层 scalar 读取改为 `yq v4 -> python3 + PyYAML -> awk fallback`。
  - 顶层 scalar 写入改为 `yq v4 -> awk fallback`；不默认用 PyYAML 写回整文件，避免丢注释或重排用户配置。
  - `port` / `socks-port` 在 `yq` 路径保持整数写入，`secret` / `external-controller` 保持字符串写入。
  - 增加 `BASH_SOURCE` 入口保护，便于无副作用 source helper。
- `webdav_copyto_relay.sh`
  - 修复后台 worker PID 记录/清理：避免命令替换子 shell PID 导致快速完成任务留下 stale `task.pid`。
  - 增加 `BASH_SOURCE` 无需调整的 fake `rclone` 回归测试覆盖：同大小 skip、不触发 copyto；stop 终止活跃 copyto 并清理 PID。
- 测试工程化
  - 新增 `scripts/test.sh`，有 `bats` 时运行 bats 包装；缺失时使用 Bash fallback。
  - 新增 `tests/webdav_copyto_relay_regression.sh`、`tests/webdav_copyto_relay.bats` 和 fake `rclone` / `sudo` fixture。
  - 新增 `tests/cf_local_writes_regression.sh`，验证本地 yml/service bundle 写入失败时能恢复旧文件。
  - 新增 `tests/mihomo_yaml_helpers_regression.sh`，验证 awk fallback 只修改顶层 YAML key 并折叠重复顶层 key。
  - `make validate` 现在同时运行语法检查、可选 lint 和回归测试；新增 `make test` 单独运行回归测试。

### 验证结果

- `bash -n cf.sh` 通过。
- `bash -n mihomo.sh` 通过。
- `bash -n webdav_copyto_relay.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试走 Bash fallback。
- 未执行真实 cloudflared 登录、Tunnel 创建/删除/重命名、systemd 启停、Mihomo 重启或 rclone WebDAV 传输。
- `cf.sh create` 若远程 tunnel 创建成功但本地文件写入失败，目前只保证本地文件回滚，不自动删除远程 tunnel，避免引入新的远程失败路径。
- `mihomo.sh` 的复杂 YAML block 仍由模板和 marker 文本逻辑管理；阶段 5 仅收敛顶层 scalar helper。

## 阶段 6：命令级 fake 回归测试和脚本一致性

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `cf.sh`、`a2up.sh`、`mount_webdav.sh` 的测试候选路径审查。
- `cf.sh`
  - `SERVICE_DIR` 支持环境变量覆盖，便于 fake systemd 目录测试。
  - `set-url` 和 `repair` 改为纯本地配置命令，不再先要求 `cloudflared --version`。
  - `repair` 修复旧格式 `- service: URL` 解析错误，改为读取 `service:` 后的完整值。
  - 新增 fake `cloudflared` / fake `systemctl` 命令级回归测试，覆盖：
    - `set-url` 安全 quote URL，且不调用 cloudflared/systemctl。
    - `repair` 从旧 ingress service 格式恢复 URL，且不调用 cloudflared/systemctl。
    - `delete` 远端删除失败时保留 yml/service/credentials。
    - `delete` 远端删除成功后才删除本地 yml/service/credentials，并执行 daemon-reload。
- `a2up.sh`
  - 增加 `BASH_SOURCE` 入口保护，便于 source helper 做无副作用测试。
  - 新增配置和 service 回归测试，覆盖：
    - `write_conf` 默认写出 `rpc-listen-all=false` 和非空 `rpc-secret`。
    - `ensure_rpc_secret` 会复用已有安全 secret。
    - `write_secret_env` 写出同一 secret 且权限为 `600`。
    - 主 aria2 service 不内联 `ARIA2_RPC_SECRET`，扫描 service 使用 `EnvironmentFile`。
    - `doctor` 能识别本机 RPC、安全 secret、secret env 文件，以及 `rpc-listen-all=true` / env 缺失异常。
- `mount_webdav.sh`
  - `SERVICE_DIR` / `SERVICE_FILE` 支持环境变量覆盖。
  - 增加 `BASH_SOURCE` 入口保护，便于 source helper 做无副作用测试。
  - 新增 fake rclone / fake systemctl 回归测试，覆盖：
    - `detect_rclone_conf_path` 使用 `SUDO_USER` 的 rclone 配置路径，并覆盖 rclone config file 空输出 fallback。
    - `config_remote` 使用同一个用户配置路径执行 delete/create/lsd，默认 vendor 为 `other`，密码走 `rclone obscure`。
    - `write_service` 写出正确 `User`、`Group`、`HOME`、`--config`、cache dir 和 `fusermount3` 路径。
    - remote 缺失时不写 service，也不执行 daemon-reload。
- 测试工程化
  - `scripts/test.sh` 接入新增：
    - `tests/cf_command_regression.sh`
    - `tests/a2up_config_service_regression.sh`
    - `tests/mount_webdav_regression.sh`
  - 修复 `webdav_copyto_relay` skip 回归测试的 PID 清理等待竞态。

### 验证结果

- `bash -n cf.sh` 通过。
- `bash -n a2up.sh` 通过。
- `bash -n mount_webdav.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 cloudflared、systemctl、aria2、rclone mount、WebDAV、Mihomo 重启或外部网络操作。
- `a2up.sh ensure_conf_ready` 对“已有配置文件但缺失/不安全 rpc-secret”的场景仍只更新内存 secret，不自动重写配置；后续可评估是否需要迁移修复。
- `mount_webdav.sh check_fuse` 仍直接检查 `/dev/fuse` 和 `/etc/fuse.conf`，尚未拆成可配置路径，因此本阶段未覆盖该写入路径。

## 阶段 7：剩余一致性和可测试性修复

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `a2up.sh`、`mount_webdav.sh` 和测试工具链审查。
- `a2up.sh`
  - 新增 `sync_conf_rpc_secret`，对已有 `aria2c.conf` 只定点修复 `rpc-secret`，不全量覆盖用户配置。
  - `ensure_conf_ready` 在已有配置缺失、不安全、重复或与当前 `RPC_SECRET` 不一致时，会同步写回一条安全 `rpc-secret`。
  - `doctor` 增加 `rpc-secret` 字符安全检查，以及 secret env 与配置一致性检查。
  - 回归测试覆盖缺失 secret、不安全 secret、重复安全 secret、显式 `RPC_SECRET` 覆盖旧值、env/config 不一致诊断。
- `mount_webdav.sh`
  - 新增 `FUSE_DEVICE` / `FUSE_CONF` 覆盖入口，并保留旧 `FUSE_DEV` 兼容默认值。
  - `check_fuse` 改为使用可覆盖路径，识别前导空白和行尾注释形式的 `user_allow_other`，不会把注释行当作启用。
  - `check_fuse` 写入逻辑改为 `tee -a "$FUSE_CONF"`，支持含空格路径并避免字符串拼接执行。
  - 回归测试覆盖缺失 FUSE 设备、缺失 fuse.conf 自动写入、避免重复追加、注释行不算启用、含空格 fuse.conf 路径。
- 测试工具链
  - `make format` 现在用 `find` 覆盖根目录、`scripts/`、`tests/` 下的 `.sh` 文件，和校验发现范围保持一致。
  - README 更新 `make validate`、`make test`、`shellcheck` / `shfmt` 可选 lint、`bats` fallback 和 `shfmt` 格式化范围说明。

### 验证结果

- `bash tests/a2up_config_service_regression.sh` 通过。
- `bash tests/mount_webdav_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 aria2、systemd、rclone mount、WebDAV、cloudflared、Mihomo 重启或外部网络操作。
- `mount_webdav.sh check_fuse` 已可测试，但真实系统上仍要求实际 `/dev/fuse` 和 `/etc/fuse.conf` 权限。

## 阶段 8：文档一致性与剩余守护脚本可测试性

日期：2026-07-05

### 已完成

- 使用主代理 + 1 个子代理完成 README 与当前脚本行为一致性、剩余高风险写入路径和测试候选项审查。
- `astr.sh`
  - 默认路径、PID 文件、日志文件、Python 路径和重启间隔支持环境变量覆盖，便于临时目录无副作用测试。
  - 新增 `BASH_SOURCE` 入口保护，source helper 不会执行主命令分发。
  - PID 文件读取改为严格单行数字校验，避免 `tr -cd` 把污染内容拼成有效 PID。
  - `terminate_process` 仅在目标 PID 本身是进程组长时才杀进程组，否则只杀目标 PID，降低误杀同号进程组风险。
  - 新增 `tests/astr_state_regression.sh`，覆盖环境变量覆盖、PID 解析和日志截断。
- `napcat.sh`
  - 新增 `BASH_SOURCE` 入口保护，便于 source helper 做无副作用测试。
  - 新增 `tests/napcat_state_regression.sh`，覆盖路径覆盖、QQ 状态文件、PID 解析和日志截断。
- `mount_webdav.sh`
  - 新增 `FUSERMOUNT_BIN` / `FUSERMOUNT_FALLBACK_BIN` 覆盖入口。
  - `install_rclone` 改为分别检查 `rclone` 与 `fusermount` / `fuse3`，已有 rclone 但缺 FUSE 工具时会单独安装 `fuse3`。
  - `tests/mount_webdav_regression.sh` 增加 fake `apt-get` 场景，验证已有 rclone 时只安装缺失的 `fuse3`，不会重复安装 rclone。
- README
  - 同步 `a2up.sh` RPC secret 迁移/修复策略和 `install` 自动部署快捷命令行为。
  - 同步 `mount_webdav.sh install` 的 rclone 与 FUSE 工具检查行为。
  - 明确 `webdav_copyto_relay.sh` 是复制远端文件、不删除远端源文件；并说明 `install` / `reconfig` / `start` 会重建同名 rclone remote。
  - 补充 WebDAV relay 默认用户名/密码。
  - 补充 Mihomo 默认 `allow-lan`、DNS 监听面和 SOCKS5 多端口组监听面的文档提示。
- 测试工程化
  - `scripts/test.sh` 接入新增 AstrBot / NapCat 状态 helper 回归测试。

### 验证结果

- `bash -n astr.sh` 通过。
- `bash -n napcat.sh` 通过。
- `bash tests/astr_state_regression.sh` 通过。
- `bash tests/napcat_state_regression.sh` 通过。
- `bash tests/mount_webdav_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 systemd 启停、rclone mount/WebDAV 传输、cloudflared 远程操作、Mihomo 重启、AstrBot/NapCat 安装或 screen/Xvfb/QQ 启动。
- `webdav_copyto_relay.sh start` 仍会重建同名 rclone remote；阶段 8 先文档显式化，后续可评估是否改为仅在 `install` / `reconfig` 重建。
- `mihomo.sh` 的核心/前端下载仍可继续收敛为临时文件验证后原子替换。
- `napcat.sh patch` 下载/编译失败时是否污染最终启动器产物仍缺少无副作用回归测试。

## 阶段 9 预期

继续收敛高风险写入路径：

- 评估并测试 `webdav_copyto_relay.sh` 的 remote 重建时机，优先减少 `start` 的配置写入副作用。
- 为 `mihomo.sh` 核心与前端安装补充无副作用回归测试，验证下载失败不破坏旧文件。
- 为 `napcat.sh patch` 补充 fake `curl` / `g++` 回归测试，验证失败不污染既有 `libnapcat_launcher.so`。
- 若环境允许，接入成熟工具 `shellcheck`、`shfmt`、`bats-core`；否则继续保持 optional/fallback 路径。
