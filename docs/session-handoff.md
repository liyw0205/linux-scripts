# 会话交接

## 当前阶段

阶段 19：New API / Sub2API 脚本文档同步

状态：实现与本地验证已完成；待提交推送后进入阶段 20。

## 本阶段完成内容

- 新增 `newapi.sh` 和 `sub2api.sh`，README 已同步文件概览、默认路径、常用命令、更新备份行为、快捷命令安装路径和依赖速查。
- `newapi.sh` / `sub2api.sh` shebang 已调整到首行。
- `newapi.sh` / `sub2api.sh` 的 `deploy` 和 `--help` 不再要求已有 `docker-compose.yml`；服务栈管理命令仍会检查对应 Compose 文件。
- `astr.sh` usage 和 README 已同步当前 `update` 行为：`fetch` upstream 后重置已跟踪文件到远端版本，保留不冲突的未跟踪文件，拒绝覆盖会与远端目标冲突的未跟踪文件。

## 验证

已执行：

```bash
bash -n newapi.sh sub2api.sh astr.sh tests/astr_install_patch_regression.sh
bash newapi.sh --help
bash sub2api.sh --help
NEWAPI_INSTALL_PATH=/data/data/com.termux/files/home/linux-scripts/.tmp-newapi-deploy-test bash newapi.sh deploy
SUB2API_INSTALL_PATH=/data/data/com.termux/files/home/linux-scripts/.tmp-sub2api-deploy-test bash sub2api.sh deploy
make validate
git diff --check
```

结果：通过。

限制：

- 当前环境缺少 `shellcheck`、`shfmt` 和 `bats`，可选 lint 会被跳过，测试使用 Bash fallback。
- 未执行真实 Docker Compose 启停、镜像更新、数据库备份、New API/Sub2API 服务运行或 AstrBot 外部仓库更新。

## 下阶段目标

阶段 20 建议目标：继续做低风险维护收敛。

实现范围：

- 测试工具链
  - 若环境允许，接入成熟工具 `shellcheck`、`shfmt`、`bats-core`。
  - 若环境不允许，继续保持 optional/fallback 路径。
- 脚本恢复提示和 fake 回归测试
  - 继续审查各脚本的真实服务边界提示。
  - 优先补足失败后人工恢复说明和无副作用 fake 回归测试。

验收标准：

- `bash scripts/test.sh` 通过。
- `make validate` 通过。
- `git diff --check` 通过。
- 不执行真实传输、真实 systemd 启停、Mihomo 重启、cloudflared 远程操作、AstrBot/NapCat 安装或外部服务部署。
- 更新 `docs/development-progress.md` 和本交接文档。

## 下一会话启动提示

读取 `docs/session-handoff.md`，按“阶段 20 建议目标：继续做低风险维护收敛”继续实施。优先保持无副作用测试和恢复提示收敛，不执行真实外部服务操作。
