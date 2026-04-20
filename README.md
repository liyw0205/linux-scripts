# linux-scripts

一些自用 Linux / WebDAV / aria2 / cloudflared / AstrBot 管理脚本，以及一个简单的 aria2 Web 管理页面。

> 适合 Debian / Ubuntu 等常见 Linux 发行版，部分脚本依赖 `systemd`。  
> 大多数脚本需要 `root` 或 `sudo` 权限。

---

## 文件列表

- [`aria2.html`](#aria2html)
- [`a2up.sh`](#a2upsh)
- [`mount_webdav.sh`](#mount_webdavsh)
- [`webdav_copyto_relay.sh`](#webdav_copyto_relaysh)
- [`cf.sh`](#cfsh)
- [`astrbot_install.sh`](#astrbot_installsh)

---

## aria2.html

一个纯前端的 **Aria2 BT / RPC 管理页面**，单文件 HTML，可直接浏览器打开使用。

### 功能

- 多服务器管理
- aria2 RPC 连接测试
- 查看服务器状态
- 查看/切换任务分类
- 批量暂停 / 恢复 / 删除任务
- 新建 URL 下载
- 新建 Torrent 下载
- BT 文件树浏览
- 按文件编号表达式快速选择文件
- 修改 aria2 运行配置
- 本地 `localStorage` 保存服务器列表

### 特点

- 单文件，无需构建
- 支持移动端侧边栏和全屏详情
- 支持文件树筛选、排序、目录勾选
- 支持 `select-file` 保存到 aria2

### 使用方法

1. 确保 aria2 已启用 RPC，例如：

   ```ini
   enable-rpc=true
   rpc-listen-all=true
   rpc-allow-origin-all=true
   rpc-secret=你的密钥
   ```

2. 直接用浏览器打开：

   ```bash
   aria2.html
   ```

   或放到任意 Web 服务器中访问。

3. 在页面里填写：
   - 服务器名称
   - RPC 地址，例如 `http://127.0.0.1:6800/jsonrpc`
   - RPC Secret

### 注意

- 前端通过浏览器直接请求 aria2 RPC，**必须处理好跨域和网络可达性**。
- 服务器信息保存在浏览器本地存储中，不加密。
- 不建议把公网可访问的 aria2 RPC 直接裸露使用。

---

## a2up.sh

一个 **aria2 + rclone 上传辅助脚本**，用于：

- 安装 aria2 / rclone / jq 等依赖
- 生成 systemd 服务
- 管理 aria2 服务
- 手动扫描下载目录
- 将符合条件的文件上传到 rclone 远端
- 上传完成后删除本地文件

当前版本标识：

```text
2026.04.20-lite-r2
```

### 功能概览

- 自动生成 aria2 配置
- 自动生成上传扫描脚本 `scan-upload.sh`
- 使用独立的 `scan-run` 手动触发上传
- 通过 aria2 RPC + `jq` 判断文件是否已完成
- 跳过 `.aria2`、`.torrent`、`.tmp`、`.part`
- 支持远端同名文件大小比较
- 使用 `flock` 防止重复扫描
- 不再自动定时扫描，改为手动触发

### 依赖

- `systemd`
- `aria2`
- `rclone`
- `curl`
- `jq`

### 常用命令

```bash
bash a2up.sh install
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

### 上传相关命令

```bash
bash a2up.sh scan-run
bash a2up.sh scan-stop
bash a2up.sh scan-status
```

### remote 相关命令

```bash
bash a2up.sh remote-check
bash a2up.sh remote-info
```

### 说明

- 本脚本**不负责创建 rclone remote**，你需要提前配置好。
- 本脚本**不负责 WebDAV 挂载**。
- 推荐先用 `mount_webdav.sh` 或自己手动配置好 rclone。

---

## mount_webdav.sh

一个基于 `rclone mount` 的 **WebDAV 挂载脚本**，自动生成并管理 `systemd` 服务。

### 功能

- 自动安装 `rclone`
- 配置 WebDAV remote
- 检查 `/dev/fuse`
- 自动写入 systemd 服务
- 启动 / 停止 / 重启 / 查看日志
- 给 aria2 提供 WebDAV 挂载目录

### 默认参数

- remote 名称：`webdav_remote`
- 挂载目录：`/mnt/webdav`
- 缓存目录：`/var/cache/rclone-webdav`
- 服务名：`rclone-webdav.service`

### 常用命令

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

### install 做了什么

- 安装 `rclone` 和 `fuse3`
- 配置 WebDAV remote
- 生成 `/etc/systemd/system/rclone-webdav.service`
- 启动挂载服务

### 推荐搭配

挂载成功后，可将 aria2 下载目录设置为：

```text
/mnt/webdav/downloads
```

---

## webdav_copyto_relay.sh

一个 **WebDAV 中转复制脚本**，通过 `rclone copyto` 实现：

- 从 WebDAV 的源路径逐个文件下载到本地临时目录
- 再上传到 WebDAV 的目标路径
- 处理完一个文件就删除本地临时文件
- 支持后台运行、停止、查看状态

适合不想 mount，只想“源目录 -> 本地临时 -> 目标目录”逐文件转运的场景。

### 特点

- 不使用 systemd
- 不需要 mount
- 用 PID 文件管理后台任务
- 有日志文件
- 自动检查本地剩余空间
- 同路径同大小文件自动跳过
- 保留目录结构

### 默认配置

- WebDAV URL：`http://127.0.0.1:5245/dav`
- 用户名：`admin`
- 密码：`root`
- 源路径：`gy/Hentai`
- 目标路径：`openlist/downloads`
- 临时目录：`/tmp/webdav_copyto_relay`
- 最低剩余空间：`30%`

### 常用命令

```bash
bash webdav_copyto_relay.sh install
bash webdav_copyto_relay.sh start
bash webdav_copyto_relay.sh stop
bash webdav_copyto_relay.sh restart
bash webdav_copyto_relay.sh status
bash webdav_copyto_relay.sh reconfig
bash webdav_copyto_relay.sh uninstall
```

### 配置文件

默认保存在脚本同目录：

```text
webdav_copyto_relay.conf
```

### 状态目录

默认：

```text
.webdav_copyto_relay/
```

其中包括：

- `task.pid`
- `relay.log`

---

## cf.sh

一个 **cloudflared Tunnel 管理脚本**，适合 Debian / Ubuntu 等带 `systemd` 的系统。

### 功能

- 自动下载并安装 `cloudflared`
- 支持多代理源加速 GitHub 下载
- 登录 Cloudflare
- 创建 / 删除 / 重命名 Tunnel
- 生成本地 yml 配置
- 生成对应 systemd 服务
- 设置 DNS
- 启停服务、查看日志、同步远端 tunnel

### 支持命令

#### 基础

```bash
bash cf.sh install
bash cf.sh patch
bash cf.sh login
bash cf.sh list
bash cf.sh info <隧道名>
bash cf.sh sync
```

#### 隧道管理

```bash
bash cf.sh create <隧道名> [穿透地址]
bash cf.sh delete <隧道名1> [隧道名2 ...]
bash cf.sh rename <旧隧道名> <新隧道名>
bash cf.sh dns <隧道名> <域名>
bash cf.sh set-url <隧道名> <穿透地址>
bash cf.sh repair <隧道名>
```

#### 服务管理

```bash
bash cf.sh enable <隧道名>
bash cf.sh disable <隧道名>
bash cf.sh restart <隧道名>
bash cf.sh stop <隧道名>
bash cf.sh status <隧道名>
bash cf.sh logs <隧道名> [行数]
```

### patch

可以把脚本安装到：

```text
/usr/local/bin/cf
```

安装后可直接使用：

```bash
cf --help
cf login
cf create my-tunnel http://127.0.0.1:8080
cf enable my-tunnel
```

### 目录

默认 cloudflared 配置目录：

```text
~/.cloudflared
```

服务文件在：

```text
/etc/systemd/system/
```

---

## astrbot_install.sh

一个用于 **AstrBot** 项目的安装 / 更新 / 卸载脚本。

### 功能

- 克隆 AstrBot Git 仓库
- 自动选择 GitHub 代理
- 下载最新 release Dashboard 资源
- 创建 Python 虚拟环境
- 安装依赖
- 生成启动脚本
- 用 `screen` 管理运行

### 支持命令

```bash
bash astrbot_install.sh install [项目名]
bash astrbot_install.sh update [项目名]
bash astrbot_install.sh uninstall [项目名]
```

### 默认项目名

```text
AstrBot
```

安装目录默认为：

```text
/root/AstrBot
```

### 安装完成后

会生成启动脚本：

```text
/bin/AstrBot_start
```

启动方式示例：

```bash
screen -dmS AstrBot /bin/AstrBot_start
```

进入会话：

```bash
screen -r AstrBot
```

### 依赖

脚本会尝试安装：

- `screen`
- `curl`
- `wget`
- `git`
- `python3`
- `python3-pip`
- `python3-venv`
- `bc`
- `tar`
- `unzip`

### 说明

- 支持自动筛选可用 GitHub 代理
- `update` 会：
  - `git pull`
  - 下载最新 Dashboard
  - 更新 Python 依赖

---

# 使用建议

---

## 1. aria2 + WebDAV 挂载

如果你希望 aria2 直接下载到 WebDAV 挂载目录：

1. 先执行：

   ```bash
   bash mount_webdav.sh install
   ```

2. 然后把 aria2 下载目录设置到：

   ```text
   /mnt/webdav/downloads
   ```

3. 再使用 `aria2.html` 进行管理。

---

## 2. aria2 本地下载 + 手动上传远端

如果你希望先下载到本地，再手动上传到 rclone 远端：

1. 先保证 `rclone remote` 已配置好
2. 执行：

   ```bash
   bash a2up.sh install
   ```

3. 下载完成后手动触发扫描上传：

   ```bash
   bash a2up.sh scan-run
   ```

4. 查看扫描状态：

   ```bash
   bash a2up.sh scan-status
   ```

---

## 3. WebDAV 目录之间转运

如果你只是想把一个 WebDAV 路径中的文件转移到另一个路径：

```bash
bash webdav_copyto_relay.sh install
bash webdav_copyto_relay.sh start
```

适合做“中转搬运”。

---

## 4. 暴露本地服务到公网

如果你要把某个本地 Web 服务暴露出去：

```bash
bash cf.sh install
bash cf.sh login
bash cf.sh create myweb http://127.0.0.1:8080
bash cf.sh enable myweb
bash cf.sh dns myweb xxx.example.com
```

---

# 环境要求

不同脚本要求不同，常见要求如下：

- Linux
- bash
- sudo / root
- systemd（`cf.sh`、`mount_webdav.sh`、`a2up.sh` 依赖）
- rclone
- aria2
- jq
- curl / wget
- screen（AstrBot 脚本）

---

# 安全提示

## WebDAV 默认账号密码

部分脚本里默认值类似：

- 用户名：`admin`
- 密码：`root`

**仅为默认占位值，不建议直接用于生产环境。**

请务必改成自己的真实配置。

## aria2 RPC

如果开启了：

```ini
rpc-listen-all=true
rpc-allow-origin-all=true
```

请同时设置：

```ini
rpc-secret=强密码
```

并尽量限制访问来源，避免公网裸露。

## cloudflared / rclone 配置

这些脚本可能涉及：

- `~/.cloudflared/cert.pem`
- `~/.cloudflared/*.json`
- `~/.config/rclone/rclone.conf`

请妥善保管，不要泄露。

---

# 免责声明

这些脚本偏向个人使用场景，提供的是“能跑”的自动化方案，不保证适用于所有发行版和环境。  
使用前请先阅读脚本内容，并按需修改默认路径、账号、密码和服务参数。

---

# License

如无特别说明，按仓库实际情况自行决定。
