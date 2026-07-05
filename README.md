# linux-scripts

自用 Linux 运维脚本集合，覆盖 aria2、rclone/WebDAV、cloudflared、Mihomo、AstrBot、NapCat，以及一个单文件 aria2 Web 管理页面。

脚本以 Debian / Ubuntu 为主要使用环境，部分脚本兼容 dnf / yum / pacman。涉及服务管理的脚本通常依赖 `systemd`，并需要 `root` 或 `sudo` 权限。

## 文件概览

| 文件 | 用途 |
| --- | --- |
| `aria2.html` | 单文件 aria2 RPC Web 管理页面 |
| `a2up.sh` | aria2 本地下载 + rclone 手动扫描上传 |
| `mount_webdav.sh` | 使用 `rclone mount` 挂载 WebDAV |
| `webdav_copyto_relay.sh` | WebDAV 源路径到目标路径的逐文件中转复制 |
| `cf.sh` | cloudflared Tunnel 创建、DNS、服务管理 |
| `mihomo.sh` | Mihomo 一体化安装、订阅、面板、端口和服务管理 |
| `astr.sh` | AstrBot 安装、更新、screen 守护和日志管理 |
| `napcat.sh` | NapCat 安装、启动器补丁、QQ 号和 screen 守护管理 |

## 通用约定

- 直接运行脚本时使用 `bash <脚本> <命令>`。
- `deploy` / `patch` 类命令会把脚本安装到 `/usr/local/bin` 下的快捷命令。
- 多数脚本支持通过环境变量覆盖默认路径、端口或服务名。
- 执行 `install` 前建议先阅读脚本顶部默认配置。

## aria2.html

纯前端 aria2 RPC 管理页面，可直接用浏览器打开，也可以放到任意 Web 服务器中访问。

主要功能：

- 多服务器配置，本地 `localStorage` 保存。
- aria2 RPC 连接测试和服务器状态展示。
- 活动、等待、停止任务汇总。
- 批量暂停、恢复、删除任务。
- 新建 URL 下载和上传 Torrent 创建任务。
- BT 文件树浏览、筛选、排序和 `select-file` 保存。
- 修改 aria2 当前运行配置。

aria2 RPC 示例配置：

```ini
enable-rpc=true
rpc-listen-all=true
rpc-allow-origin-all=true
rpc-secret=你的密钥
```

浏览器中填写 RPC 地址，例如：

```text
http://127.0.0.1:6800/jsonrpc
```

## a2up.sh

aria2 + rclone 上传辅助脚本。默认把 aria2 下载到本地目录，完成后由手动扫描任务上传到 rclone remote，并删除已上传的本地文件。

当前版本：

```text
2026.04.20-lite-r2
```

默认值：

- 安装目录：`/opt/aria2c`
- 下载目录：`/data/aria2-staging`
- aria2 服务：`aria2c.service`
- 扫描服务：`a2up-scan.service`
- rclone remote：`webdav_remote`
- 远端目录前缀：`downloads`
- 快捷安装目标：`/usr/local/bin/a2up`

常用命令：

```bash
bash a2up.sh install
bash a2up.sh patch
bash a2up.sh start
bash a2up.sh stop
bash a2up.sh restart
bash a2up.sh status
bash a2up.sh logs 200
bash a2up.sh info
bash a2up.sh reconfig
bash a2up.sh doctor
bash a2up.sh uninstall
```

remote 检查：

```bash
bash a2up.sh remote-check
bash a2up.sh remote-info
```

手动扫描上传：

```bash
bash a2up.sh scan-run
bash a2up.sh scan-stop
bash a2up.sh scan-pause
bash a2up.sh scan-status
```

说明：

- 不创建 rclone remote，需要提前配置好。
- 不负责 WebDAV 挂载。
- 不再使用定时扫描，上传由 `scan-run` 手动触发。
- 扫描脚本使用 `flock` 防止重复运行。

## mount_webdav.sh

基于 `rclone mount` 的 WebDAV 挂载脚本，会生成并管理 systemd 服务。

默认值：

- remote 名称：`webdav_remote`
- 挂载目录：`/mnt/webdav`
- 缓存目录：`/var/cache/rclone-webdav`
- 服务名：`rclone-webdav.service`

常用命令：

```bash
bash mount_webdav.sh install
bash mount_webdav.sh reconfig
bash mount_webdav.sh start
bash mount_webdav.sh stop
bash mount_webdav.sh restart
bash mount_webdav.sh status
bash mount_webdav.sh logs 100
bash mount_webdav.sh tip
bash mount_webdav.sh uninstall
```

`install` 会安装 `rclone` / `fuse3`、交互配置 WebDAV remote、写入 systemd 服务并启动挂载。

## webdav_copyto_relay.sh

WebDAV 逐文件中转复制脚本。流程是源 WebDAV 路径下载到本地临时目录，再上传到目标 WebDAV 路径，处理完单个文件后删除本地临时文件。

适用场景：

- 不想使用 `rclone mount`。
- 需要把同一 WebDAV remote 内的一个目录搬到另一个目录。
- 需要可停止、可查看进度的后台任务。

默认值：

- WebDAV URL：`http://127.0.0.1:5244/dav`
- remote 名称：`webdav_relay_remote`
- 源路径：`gy/Hentai`
- 目标路径：`downloads`
- 临时目录：`/tmp/webdav_copyto_relay`
- 配置文件：`webdav_copyto_relay.conf`
- 状态目录：`.webdav_copyto_relay/`

常用命令：

```bash
bash webdav_copyto_relay.sh install
bash webdav_copyto_relay.sh start
bash webdav_copyto_relay.sh stop
bash webdav_copyto_relay.sh restart
bash webdav_copyto_relay.sh status
bash webdav_copyto_relay.sh reconfig
bash webdav_copyto_relay.sh uninstall
```

## cf.sh

cloudflared Tunnel 管理脚本，支持安装 cloudflared、登录 Cloudflare、创建隧道、写入配置、生成 systemd 服务、绑定 DNS、启停服务和同步远端 Tunnel。

基础命令：

```bash
bash cf.sh install
bash cf.sh patch
bash cf.sh login
bash cf.sh list
bash cf.sh info <隧道名>
bash cf.sh sync
```

隧道管理：

```bash
bash cf.sh create <隧道名> [穿透地址]
bash cf.sh delete <隧道名1> [隧道名2 ...]
bash cf.sh rename <旧隧道名> <新隧道名>
bash cf.sh dns <隧道名> <域名>
bash cf.sh set-url <隧道名> <穿透地址>
bash cf.sh repair <隧道名>
```

服务管理：

```bash
bash cf.sh enable <隧道名>
bash cf.sh disable <隧道名>
bash cf.sh restart <隧道名>
bash cf.sh stop <隧道名>
bash cf.sh status <隧道名>
bash cf.sh logs <隧道名> [行数]
```

安装快捷命令：

```bash
bash cf.sh patch
cf login
cf create myweb http://127.0.0.1:8080
cf enable myweb
```

## mihomo.sh

Mihomo Linux 一体化管理脚本。支持核心安装、systemd 服务、订阅导入、自动代理组、前端切换、端口修改、SOCKS5 多端口组和 `Country.mmdb` 修复。

默认值：

- Mihomo 版本：`v1.19.12`
- 配置目录：`/etc/mihomo`
- 核心目录：`/opt/mihomo`
- 配置文件：`/etc/mihomo/config.yaml`
- 服务文件：`/etc/systemd/system/mihomo.service`
- 默认 HTTP 端口：`7890`
- 默认 SOCKS5 端口：`7891`
- 默认管理端口：`0.0.0.0:9090`
- 默认前端：`MetaCubeXD`

安装和服务：

```bash
sudo bash mihomo.sh install
sudo bash mihomo.sh uninstall
sudo bash mihomo.sh start
sudo bash mihomo.sh stop
sudo bash mihomo.sh restart
sudo bash mihomo.sh status
sudo bash mihomo.sh logs
sudo bash mihomo.sh test
```

订阅和代理组：

```bash
sudo bash mihomo.sh sub <订阅链接>
sudo bash mihomo.sh groups
```

端口和前端：

```bash
sudo bash mihomo.sh port 8899
sudo bash mihomo.sh http 7890
sudo bash mihomo.sh socks 7891
sudo bash mihomo.sh frontend metacubexd
sudo bash mihomo.sh frontend zashboard
sudo bash mihomo.sh frontend-info
```

SOCKS5 多端口组：

```bash
sudo bash mihomo.sh socks-group on 10
sudo bash mihomo.sh socks-group status
sudo bash mihomo.sh socks-group off
```

安装后会创建快捷命令：

```bash
mihomoctl status
mihomoctl sub <订阅链接>
mihomoctl port 8899
mihomoctl frontend zashboard
```

同时兼容：

```bash
clashon
clashoff
clashstatus
clashlog
clashrestart
clashfrontend
clashuninstall
```

## astr.sh

AstrBot 单文件管理脚本，默认管理 `/root/AstrBot` 项目和 `/root/myenv` 虚拟环境，使用 `screen` 启动守护进程，异常退出后自动重启，并带日志截断。

默认值：

- 应用目录：`/root/AstrBot`
- 虚拟环境：`/root/myenv`
- 日志文件：`/root/AstrBot/astr.log`
- screen 会话：`AstrBot`
- 快捷命令：`/usr/local/bin/astr`

常用命令：

```bash
bash astr.sh deploy
astr install
astr patch
astr start
astr stop
astr restart
astr status
astr log
```

也可以不部署，直接运行：

```bash
bash astr.sh install
bash astr.sh start
```

## napcat.sh

NapCat 单文件管理脚本，支持下载安装 NapCat、下载并编译 Linux 启动器补丁、设置启动 QQ 号、使用 `screen` 守护运行、异常退出自动重启、日志截断和状态查看。

默认值：

- 基础目录：`/root`
- NapCat 目录：`/root/napcat`
- 启动器补丁：`/root/libnapcat_launcher.so`
- 配置目录：`/root/.config/napcat-cli`
- 状态目录：`/root/.local/state/napcat-cli`
- screen 会话：`napcat`
- 快捷命令：`/usr/local/bin/napcat`

常用命令：

```bash
bash napcat.sh deploy
napcat install
napcat patch
napcat start
napcat stop
napcat restart
napcat status
napcat log
```

设置或清空启动 QQ 号：

```bash
napcat -q 3834455831
napcat -q 3834455831 start
napcat -q
```

## 常见组合

aria2 直接下载到 WebDAV 挂载目录：

```bash
bash mount_webdav.sh install
bash mount_webdav.sh tip
```

aria2 本地下载，完成后手动上传远端：

```bash
bash a2up.sh install
bash a2up.sh scan-run
bash a2up.sh scan-status
```

WebDAV 路径之间中转搬运：

```bash
bash webdav_copyto_relay.sh install
bash webdav_copyto_relay.sh start
bash webdav_copyto_relay.sh status
```

暴露本地服务：

```bash
bash cf.sh install
bash cf.sh login
bash cf.sh create myweb http://127.0.0.1:8080
bash cf.sh enable myweb
```

部署代理服务和 Web 面板：

```bash
sudo bash mihomo.sh install
sudo bash mihomo.sh sub <订阅链接>
sudo bash mihomo.sh status
```

部署机器人守护：

```bash
bash astr.sh deploy
astr install
astr start

bash napcat.sh deploy
napcat install
napcat patch
napcat -q <QQ号> start
```

## 依赖速查

| 脚本 | 主要依赖 |
| --- | --- |
| `a2up.sh` | `systemd`, `aria2`, `rclone`, `curl`, `jq` |
| `mount_webdav.sh` | `systemd`, `rclone`, `fuse3` |
| `webdav_copyto_relay.sh` | `rclone`, `bash`, `sudo/root` |
| `cf.sh` | `systemd`, `cloudflared`, `curl` 或 `wget` |
| `mihomo.sh` | `systemd`, `curl`, `wget`, `unzip`, `tar`, `gzip`, `file` |
| `astr.sh` | `git`, `python3`, `python3-venv`, `pip`, `screen` |
| `napcat.sh` | `curl`, `git`, `node/npm`, `make/gcc`, `xvfb`, `screen`, `qq` |

## 备注

- `astrbot_install.sh` 已移除，当前 AstrBot 管理由 `astr.sh` 负责。
- `README.md` 按当前项目脚本重新整理，命令以脚本内 `usage` 为准。
