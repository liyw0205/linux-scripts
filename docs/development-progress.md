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

## 阶段 9：高风险写入路径收敛

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `webdav_copyto_relay.sh`、`mihomo.sh` 和 `napcat.sh patch` 高风险写入路径审查。
- `webdav_copyto_relay.sh`
  - 新增 `ensure_remote_available`，`start` 只做 remote 可用性与路径存在性检查。
  - `start` 不再调用 `config_remote`，不会在普通启动时执行 `rclone config delete/create` 或 `rclone obscure`。
  - fake `rclone` fixture 增加 remote 不可用模式。
  - 回归测试覆盖：
    - `start` 成功路径不会重写 rclone 配置。
    - remote 不可用时 `start` 失败且不写 rclone 配置、不留下任务 PID。
- `mihomo.sh`
  - `download_file` 改为写入同目录临时文件，校验大小和 HTML/XML 类型后再 `mv -f` 到目标，失败保留旧文件。
  - `backup_file` 改为 `mktemp` 唯一备份名并使用 `cp -p` 保留元数据。
  - 核心安装改为解压到 `MIHOMO_BIN` 同目录临时文件，`gunzip` 和 `chmod` 成功后再替换最终核心。
  - 新增 `replace_dir_with_backup`，前端安装先解压到 `MIHOMO_DIR` 下 staging 目录，校验 `index.html` 后再替换 UI；替换失败会恢复旧 UI。
  - `install_metacubexd` / `install_zashboard` 下载失败、坏包或解压失败时不再删除旧 UI。
  - 新增 `tests/mihomo_install_atomic_regression.sh`，覆盖下载 HTML、坏 gzip、前端下载失败、坏 tar、坏 zip 均保留旧产物。
- `napcat.sh`
  - `patch_napcat` 改为临时下载 `launcher.cpp`、临时编译 `.so`、临时 `chmod` 成功后再发布最终 `libnapcat_launcher.so`。
  - `curl` 下载增加 `-fSL`、连接超时和总超时，避免 HTTP 错误页被当作源码。
  - 下载、编译或 `chmod` 失败时保留既有 `launcher.cpp` 和 `libnapcat_launcher.so`。
  - 新增 `tests/napcat_patch_regression.sh`，覆盖 fake `curl` 失败、fake `g++` 失败和 fake `chmod` 失败。
- README
  - 同步 `webdav_copyto_relay.sh start` 新行为：只做只读检查，不重建 rclone remote。
- 测试工程化
  - `scripts/test.sh` 接入新增 Mihomo 安装原子性和 NapCat patch 原子性回归测试。

### 验证结果

- `bash -n webdav_copyto_relay.sh` 通过。
- `bash -n mihomo.sh` 通过。
- `bash -n napcat.sh` 通过。
- `bash tests/webdav_copyto_relay_regression.sh all` 通过。
- `bash tests/mihomo_install_atomic_regression.sh` 通过。
- `bash tests/napcat_patch_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 rclone 配置/传输、WebDAV 访问、Mihomo 下载/重启、NapCat 下载/编译、systemd 启停或外部服务部署。
- `webdav_copyto_relay.sh config_remote` 在 `install` / `reconfig` 中仍是 delete/create 后测试，失败可能影响同名 remote；阶段 9 先移除 `start` 副作用，后续可继续收敛配置写入事务。
- `webdav_copyto_relay.sh reconfig` 仍先保存本地配置再重建 remote，失败恢复策略可继续完善。
- `mihomo.sh download_country_mmdb` / `repair_mmdb` 仍会先删除旧 mmdb 再下载，后续可复用本阶段的下载原子化思路继续修复。

## 阶段 10：配置写入和 mmdb 下载失败恢复

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `webdav_copyto_relay.sh` 配置写入恢复、`mihomo.sh` mmdb 下载保护审查和提交前只读复核。
- `webdav_copyto_relay.sh`
  - `save_config` 改为同目录临时文件写入后 `mv`，避免直接截断 `CONFIG_FILE`。
  - `config_interactive` 改为只收集变量，不立即保存配置。
  - `config_remote` 改为先使用临时 rclone config 创建 probe remote，并在 probe remote 上完成 `lsd` 和源/目标路径验证，验证失败不触碰真实同名 remote。
  - 真实 remote 提交阶段改为存在则 `rclone config update`，不存在才 `config create`，不再先 `config delete`。
  - `reconfig_cmd` 在 remote 连接与远端路径验证成功、真实 remote 提交成功后才保存新配置；失败时恢复旧配置或删除新配置。
  - `ensure_remote_available` / `ensure_remote_paths_exist` 改为返回失败，便于上层恢复配置。
  - fake `rclone` fixture 支持 `--config` probe、`config update/create/delete/listremotes` 和失败模式。
  - Bats 包装同步覆盖所有 Bash fallback 子用例，避免有 `bats` 时漏跑新场景。
  - 提交前复核发现路径验证失败仍可能污染真实 remote，已将源/目标路径验证前移到临时 probe remote。
  - 回归测试新增：
    - probe 失败时不触碰真实 remote，且恢复旧配置。
    - probe 路径检查失败时不触碰真实 remote，且恢复旧配置。
    - reconfig 成功时更新配置并 update 已有 remote。
    - 最终 remote update 失败时恢复旧配置且不 delete 旧 remote。
- `mihomo.sh`
  - `check_country_mmdb` 支持传入候选文件路径。
  - `download_country_mmdb` 支持 `--force`；下载到候选文件，校验有效后才发布到 `Country.mmdb`。
  - `download_country_mmdb` 失败或下载无效 payload 时保留旧 `Country.mmdb`、`country.mmdb` 和 `geoip.metadb`。
  - `repair_mmdb` 不再先删除旧 mmdb，改为 force 下载成功后再测试/重启。
  - 前端 staging 增加 `prepare_frontend_stage`，支持压缩包带单层目录并确保最终 `UI_DIR/index.html` 存在。
  - `tests/mihomo_install_atomic_regression.sh` 增加核心成功、MetaCubeXD/Zashboard 成功、mmdb 下载失败、无效 payload 和成功发布测试。
- README
  - 同步 `webdav_copyto_relay.sh install/reconfig` 新行为：先验证配置，再创建或更新同名 rclone remote。

### 验证结果

- `bash tests/webdav_copyto_relay_regression.sh all` 通过。
- `bash tests/mihomo_install_atomic_regression.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 rclone 配置/传输、WebDAV 访问、Mihomo 下载/重启、systemd 启停或外部服务部署。
- `webdav_copyto_relay.sh config_remote` 最终 `rclone config update` 失败时无法证明真实 rclone 内部完全未改配置；当前脚本先用临时 remote 完成连接和路径验证，避免验证失败污染真实 remote，并避免 delete/create 破坏旧 remote。
- 可继续审查其他脚本的安装/卸载路径，例如 `astr.sh install/patch`、`napcat.sh install`、`cf.sh install` 的下载和部署失败恢复。

## 阶段 11：安装/下载失败恢复收敛

日期：2026-07-05

### 已完成

- 使用主代理 + 3 个子代理完成 `astr.sh`、`napcat.sh` 和 `cf.sh` 安装/下载失败恢复审查。
- `astr.sh`
  - `install_astr` 新安装改为 staging clone + staging venv：先完成 git clone、venv 创建和依赖安装，全部成功后再发布最终 `APP_DIR` / `VENV_DIR`。
  - `install_astr` 对已有完整安装不再原地重装；已有 repo 但缺失 venv 时只通过 staging 创建 venv。
  - `install_astr` 对非空非完整目录拒绝覆盖，避免把残缺目录当成安装源继续污染环境。
  - Python 依赖安装改为显式使用 `${VENV_DIR}/bin/python -m pip`，不再依赖裸 `pip`。
  - `patch_astr` 要求工作区干净、远端更新为 fast-forward；移除普通 `git pull` merge fallback。
  - `patch_astr` 先根据目标 commit 的 `requirements.txt` 构建新 venv，成功后再 fast-forward 代码并替换 venv；失败保留旧 HEAD 和旧 venv。
  - 新增 `tests/astr_install_patch_regression.sh`，覆盖 clone 失败、pip 失败、已有 repo 缺失 venv、patch 依赖失败的恢复行为。
- `napcat.sh`
  - `install_napcat` 改为临时目录下载 installer，使用 `curl -fSL`、连接/总超时、非空校验和 `bash -n` 校验。
  - installer 下载、校验或执行失败时不覆盖旧 `napcat-install.sh`，并清理临时目录。
  - installer 执行成功后才发布到 `${BASE_DIR}/napcat-install.sh`。
  - 新增 `tests/napcat_install_regression.sh`，覆盖 partial、空文件、语法错误 payload、installer 执行失败和成功发布。
- `cf.sh`
  - `http_get` 的 curl 路径增加 `-fSL`，避免 HTTP 错误页被当作有效下载。
  - `download_with_proxies` 每次失败后删除输出文件，最终失败前兜底清理 partial。
  - `install_cloudflared` 改为下载候选验证后，再写入目标目录 staging 文件并验证，最后 `mv` 发布；发布失败或最终验证失败时恢复旧二进制。
  - 本地 yml/service bundle 回滚失败时保留备份文件并报错，避免恢复证据被提前删除。
  - `tests/cf_local_writes_regression.sh` 增加原先不存在 yml/service 时失败回滚应删除新产物的覆盖。
  - 新增 `tests/cf_install_download_regression.sh`，覆盖无效下载、发布阶段失败、成功发布和 `download_with_proxies` partial 清理。
- README
  - 同步 `cf.sh install`、`astr.sh install/patch`、`napcat.sh install/patch` 的失败恢复行为说明。
- 测试工程化
  - `scripts/test.sh` 接入新增 AstrBot、NapCat 和 cloudflared 回归测试。

### 验证结果

- `bash -n astr.sh napcat.sh cf.sh tests/astr_install_patch_regression.sh tests/napcat_install_regression.sh tests/cf_install_download_regression.sh scripts/test.sh` 通过。
- `bash tests/astr_install_patch_regression.sh` 通过。
- `bash tests/napcat_install_regression.sh` 通过。
- `bash tests/cf_install_download_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 被跳过，测试继续使用 Bash fallback。
- 未执行真实 cloudflared 下载/安装、Cloudflare 远程操作、systemd 启停、AstrBot/NapCat 安装、screen/Xvfb/QQ 启动或外部服务部署。
- `astr.sh patch` 仍会在 patch 成功发布 venv 后才切换到新环境；若运行中的进程已加载旧代码，需要用户按需重启服务。
- `napcat.sh install` 仍执行上游 installer，本阶段只保证 installer 文件下载/发布不污染旧产物，不拦截上游 installer 内部副作用。

## 阶段 12：AstrBot update 命令和运行提示

日期：2026-07-05

### 已完成

- 使用主代理 + 1 个子代理完成 `astr.sh update` 命令设计审查和实现。
- `astr.sh`
  - 新增 `update_astr`，面向日常更新：在 `APP_DIR` 执行 `git pull --ff-only`，再进入现有虚拟环境刷新依赖。
  - `install_requirements` 改为显式 source `${VENV_DIR}/bin/activate` 后执行 `python -m pip`，满足进入虚拟环境安装依赖的行为。
  - `update_astr` 检查 `.git`、虚拟环境和干净工作区；依赖安装失败时回退本次 `git pull` 带来的 HEAD 变化。
  - `update_astr` 检测到 supervisor 或 app 正在运行时提示执行 `astr restart` 使更新生效。
  - `install_astr` 已有完整安装时提示使用 `astr update`。
  - CLI 增加 `astr update` 分支，`patch` 保留为更严格的 staging 更新路径。
  - `tests/astr_install_patch_regression.sh` 增加 update 成功、必须进入虚拟环境、依赖失败回退代码的覆盖。
- README
  - 常用命令和组合示例加入 `astr update`。
  - 同步说明 `update` 是 `git pull --ff-only` 后进入现有虚拟环境安装依赖，`patch` 是更严格的 staging 更新路径。

### 验证结果

- `bash -n astr.sh tests/astr_install_patch_regression.sh` 通过。
- `bash tests/astr_install_patch_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过。
- 未执行真实 AstrBot 安装、真实 `git pull` 外部仓库更新、screen 启停或服务重启。
- `update` 复用现有 venv 原地安装依赖；若 pip 在包级别部分升级后失败，脚本只能回退本次代码更新，不能完整还原虚拟环境包状态。需要完整 venv 原子替换时继续使用 `patch`。

## 阶段 13：Mihomo HTTP/SOCKS5 共用代理认证

日期：2026-07-06

### 已完成

- 使用主代理 + 1 个子代理完成 Mihomo 入站代理认证方案审查。
- `mihomo.sh`
  - 新增顶层 `authentication` 代理认证管理，HTTP 和 SOCKS5 共用同一组用户名/密码。
  - 新增 `auth|proxy-auth|authentication` 命令：
    - `auth set <用户名> [密码]` 设置认证，省略密码时隐藏输入。
    - `auth <用户名> <密码>` 兼容直接设置。
    - `auth status` 查看状态，不输出明文密码。
    - `auth off` 清除认证。
  - 新增交互菜单入口“设置 HTTP / SOCKS5 代理认证”。
  - `show_access_info` 显示代理认证启用状态和用户名，密码始终脱敏。
  - 新增 YAML 单引号 quote/unquote 和顶层 block helper，只操作 column 0 的 `authentication`，避免误删嵌套字段。
  - `create_subscription_config` 重建订阅配置时保留现有 `authentication` 和 `skip-auth-prefixes`，避免 `sub` / `groups` 丢认证。
  - SOCKS5 多端口组继续不写 `users: []`，保持继承全局认证。
- `tests/mihomo_yaml_helpers_regression.sh`
  - 覆盖认证写入、单引号和 `#` 字符安全 round-trip。
  - 覆盖只删除顶层 `authentication`，不触碰嵌套 `authentication`。
  - 覆盖订阅配置重建保留认证和 `skip-auth-prefixes`。
  - 覆盖命令层设置/清除认证且输出不泄露密码。
- README 同步 Mihomo 认证命令和行为说明。

### 验证结果

- `bash -n mihomo.sh tests/mihomo_yaml_helpers_regression.sh` 通过。
- `bash tests/mihomo_yaml_helpers_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过，测试继续使用 Bash fallback。
- 未执行真实 Mihomo 安装、配置测试、systemd 重启或外部下载。
- 命令行形式 `auth <用户名> <密码>` 便于自动化，但密码会进入 shell history；人工使用建议 `auth set <用户名>` 后隐藏输入密码。

## 阶段 14：Mihomo 订阅更新命令

日期：2026-07-06

### 已完成

- 使用主代理 + 1 个子代理完成 Mihomo 订阅更新方案审查和实现。
- `mihomo.sh`
  - 新增 `SUB_URL_FILE="$MIHOMO_DIR/subscription.url"`，导入订阅成功后持久化原始订阅链接。
  - 新增 `sub update`、`update-sub`、`sub status` 命令：
    - `sub update` 使用已保存链接重新下载订阅并重建代理组配置。
    - `update-sub` 作为兼容别名。
    - `sub status` 只显示是否已保存链接，不输出订阅 URL 明文。
  - `sub` 无参数时隐藏输入订阅链接，减少 token 泄露到终端回显。
  - 订阅下载改用专用 helper，通过 `curl --config -` 从 stdin 传入 URL，避免 URL 出现在 curl argv 中。
  - 订阅 URL 文件用同目录临时文件 + `mv` 原子发布，并设置 `600` 权限。
  - 订阅下载失败、HTML 响应或文件过小时不替换旧 `subscription.yaml`，也不覆盖旧 URL。
  - 交互菜单增加“更新订阅”。
- `tests/mihomo_subscription_update_regression.sh`
  - 覆盖导入成功后写入 `subscription.yaml` 和 `subscription.url`。
  - 覆盖 `sub update` / `update-sub` 使用已保存 URL 更新订阅。
  - 覆盖无 URL 文件时中文报错。
  - 覆盖 HTML、过小文件等失败路径保留旧订阅和旧 URL。
  - 覆盖命令输出不泄露订阅 token，且 URL 不进入 curl argv。
- README 同步 Mihomo 订阅导入、更新和状态命令。
- `scripts/test.sh` 接入新增订阅更新回归测试。

### 验证结果

- `bash -n mihomo.sh tests/mihomo_subscription_update_regression.sh scripts/test.sh` 通过。
- `bash tests/mihomo_subscription_update_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过，测试继续使用 Bash fallback。
- 未执行真实订阅网络下载、Mihomo 配置测试、systemd 重启或外部服务部署。
- 命令行形式 `sub <订阅链接>` 便于自动化，但订阅链接会进入 shell history；人工使用建议执行 `sub` 后隐藏输入。

## 阶段 15：运行时清理和恢复提示收敛

日期：2026-07-06

### 已完成

- `cf.sh`
  - `rename` 在远端重命名成功但本地 yml/service 写入失败时，明确提示远端已经改名、旧本地配置仍保留、旧服务已停止/禁用，以及后续 `cf sync`、`cf set-url`、必要时 `cf enable` 的人工恢复步骤。
  - `sync` 在单个远端隧道本地写入失败时，明确提示远端未修改、失败项已尝试回滚、前序已同步项不会自动回滚，并清理临时列表后退出。
  - `tests/cf_command_regression.sh` 增加 fake `rename` 和 `sync` 本地写入失败场景，覆盖提示内容、回滚结果和临时文件清理。
- `napcat.sh`
  - 新增 PID 退出等待和定向终止 helper，避免停止时误杀当前调用者所在进程组。
  - `_run` 停止 QQ / Xvfb 时先 TERM、再按需 KILL，并对 QQ 子进程树做定向清理。
  - `stop_napcat` 的 TERM/KILL 等待窗口改为可通过环境变量调整，默认更快升级，避免 QQ 忽略 TERM 时长时间卡住。
  - `tests/napcat_runtime_regression.sh` 增加 fake Xvfb/QQ 无副作用运行时测试，覆盖 QQ 忽略 TERM 时 `stop_napcat` 能及时停止 `_run`、QQ 子进程和 PID/stop 文件清理。
  - `scripts/test.sh` 接入新增 NapCat runtime 回归测试。

### 验证结果

- `bash tests/cf_command_regression.sh` 通过。
- `bash tests/cf_local_writes_regression.sh` 通过。
- `bash tests/napcat_runtime_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过，测试继续使用 Bash fallback。
- 未执行真实 cloudflared 远程操作、真实 systemd 启停、真实 NapCat/QQ/Xvfb 运行或外部服务部署。

## 阶段 16：WebDAV mount remote 配置失败恢复

日期：2026-07-06

### 已完成

- `mount_webdav.sh`
  - `config_remote` 不再先删除真实同名 remote。
  - 新配置会先写入临时 rclone config，并在 probe remote 上完成连接测试；probe 失败时真实 remote 不被修改。
  - probe 成功后再检查真实配置中是否存在同名 remote：存在则 `rclone config update`，不存在才 `config create`。
  - 最终 update 失败时提示“未主动删除旧 remote”，并给出真实配置文件路径。
  - 探测临时配置在成功、probe 失败和最终提交失败路径都会清理。
- `tests/mount_webdav_regression.sh`
  - fake `rclone` 覆盖 probe config、真实 update、真实 create、probe lsd 失败和最终 update 失败。
  - 覆盖不再执行 `config delete`、probe 失败不触碰真实 remote、临时配置清理。

### 验证结果

- `bash -n mount_webdav.sh tests/mount_webdav_regression.sh` 通过。
- `bash tests/mount_webdav_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过，测试继续使用 Bash fallback。
- 未执行真实 rclone WebDAV 配置、真实 mount、真实 systemd 启停或外部服务部署。
- `rclone config update` 内部若部分写入后失败，脚本只能保证不主动 delete 旧 remote，不能证明 rclone 内部完全无副作用。

## 阶段 17：Cloudflare create 本地失败恢复提示

日期：2026-07-06

### 已完成

- `cf.sh`
  - `create` 在远端 tunnel 创建成功但本地 yml/service 写入失败时，明确提示远端 tunnel 已经存在、远端 ID、本地文件已尝试回滚。
  - 恢复建议明确为：修复本地写入/权限问题后执行 `cf sync`；如果不保留远端 tunnel，则执行 `cf delete <隧道名>`。
- `tests/cf_command_regression.sh`
  - fake `cloudflared` 支持 `tunnel create` 后在 `tunnel list` 中暴露新 tunnel，模拟真实创建后的查询流程。
  - 覆盖 `create` 远端成功、本地 service 写入失败时的提示内容和本地回滚结果。

### 验证结果

- `bash -n cf.sh tests/cf_command_regression.sh` 通过。
- `bash tests/cf_command_regression.sh` 通过。
- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。

### 发现但未完成

- 当前环境仍缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 仍会跳过，测试继续使用 Bash fallback。
- 未执行真实 cloudflared 远程创建/删除、真实 systemd 启停或外部服务部署。

## 阶段 18 预期

继续做低风险维护收敛：

- 视环境补齐 `shellcheck`、`shfmt`、`bats-core` 可选工具链，或继续保持 fallback。
- 继续审查各脚本的真实服务边界提示，优先补足失败后人工恢复说明和无副作用 fake 回归测试。
