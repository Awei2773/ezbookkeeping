# ezBookkeeping 本地开发环境（团队二开）

这是团队二开主线的本地开发说明。生产/官方文档见 `README.md`；
开发工作流与上游同步细节见 `docs/dev/DEV_WORKFLOW.md`。

---

## 一、3 条命令跑起来

前置：NAS 上已装 Docker + Compose，当前用户能访问 docker（在 docker 组）。
**不需要在宿主装 Go / Node / GCC**，全部在容器内构建。

```bash
# 1. 复制环境变量（首次）
cp .env.example .env
#    编辑 .env，至少把 EBK_SECURITY_SECRET_KEY 填成随机值： openssl rand -hex 32

# 2. 启动（首次会拉镜像 + 构建，较慢）
./scripts/dev-up.sh

# 3. 打开前端
#    http://<NAS-IP>:8081/   （Vite 热更新，API 代理到后端 :8080）
```

- 后端：`:8080`（Go，改 `.go` 文件自动重编译重启，轮询 2s）
- 前端：`:8081`（Vite dev server，HMR）
- 健康检查：`curl http://localhost:8080/healthz.json`
- 日志：`docker compose -f docker-compose.dev.yml logs -f backend frontend`
- 停止：`./scripts/dev-down.sh`

---

## 二、常见故障 5 条

1. **`./scripts/dev-up.sh` 报端口被占用** —— 8080/8081 已被其它进程占用。
   `ss -ltnp | grep -E '8080|8081'` 找到后停掉，或改 `docker-compose.dev.yml` 的端口映射。

2. **前端 HMR 不刷新（NAS 网络盘挂载）** —— inotify 事件没传进容器。
   在 `docker-compose.dev.yml` 的 frontend 里打开 `CHOKIDAR_USEPOLLING: "true"` 后重启。
   后端已内置轮询，无此问题。

3. **首次 `docker compose up` 卡在拉镜像/下载 Node** —— 网络慢。耐心等；
   失败则检查 NAS 能否访问 `nodejs.org` 与 docker hub，重跑 `./scripts/dev-up.sh`。

4. **容器内写 `data/` 报权限错误** —— `data/ storage/ log/` 目录属主不是 uid 1000。
   修复（以当前用户 uid 1000 执行）：`sudo chown -R 1000:1000 data storage log`。

5. **注册后想关掉注册开关** —— 改 `.env` 加 `EBK_USER_ENABLE_REGISTER=false` 并重启 backend，
   **不要改 `conf/ezbookkeeping.ini`**（上游高频改动，改了会制造冲突）。

---

## 三、怎么同步上游、怎么发版

### 同步上游
```bash
./scripts/sync-upstream.sh            # 自动：fetch → 备份 data/ → ff-only main
# 按提示手工合并：
git checkout feat/local-dev
git merge --no-ff main -m "sync: upstream vX.Y.Z"   # 冲突按文档处理
./scripts/sync-upstream.sh --continue # 跑测试门禁，全绿才打 tag
```
完整 SOP 与冲突处理优先级表见 `docs/dev/DEV_WORKFLOW.md` 第 F 节。

### 发版（打 tag，不改 package.json）
```bash
git checkout feat/local-dev
git tag my/v<上游版本>-<序号>        # 例如 my/v2.2.0-1
git push origin feat/local-dev my/v2.2.0-1
```
版本号永远只通过 git tag 表达，`package.json` 里的 `version` 保持与上游一致、禁止修改。
