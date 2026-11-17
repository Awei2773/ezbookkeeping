# 二开改动清单（CHANGELOG）

> 记录**相对上游的本地改动文件清单**。每次 `sync: upstream` 后照此清单核对，
> 检查上游是否动了同名文件、是否需要重新适配。
> 版本只通过 git tag（`my/v<上游版本>-<序号>`）表达，**不改 package.json 的 version**。

## 基线

- 基线 tag：`my/v2.1.1-0`（= 上游 `9d695811`）
- 分支：`feat/local-dev`（从 `main` 检出，`main` 与 `upstream/main` 完全一致）

## 新增文件（开发环境基础设施，与上游无冲突面）

| 文件 | 用途 |
|---|---|
| `docker/dev/Dockerfile.build` | 后端/打包构建镜像（Go 1.27 + gcc/CGO + Node 26 + git，uid 1000） |
| `docker/dev/Dockerfile.frontend` | 前端 dev 镜像（node:26 + git） |
| `docker/dev/Dockerfile.prod` | 生产镜像（预编译静态资源，供日常/远程访问，端口 8082） |
| `docker/dev/backend-dev.sh` | 后端热重载（轮询，NAS inotify 降级方案） |
| `docker-compose.dev.yml` | 开发环境编排（backend/frontend/db[可选]） |
| `docker-compose.prod.yml` | 生产部署编排（app，端口 8082） |
| `.dockerignore` | 构建上下文排除 node_modules/数据/密钥等 |
| `.env.example` | 环境变量模板（不入库的 `.env` 从它复制） |
| `docs/dev/DEV_WORKFLOW.md` | 二开工作流文档 |
| `docs/dev/CHANGELOG.md` | 本清单 |
| `scripts/dev-up.sh` / `scripts/dev-down.sh` | 开发环境一键启停 |
| `scripts/sync-upstream.sh` | 上游同步半自动脚本 |
| `README.LOCAL.md` | 本地快速上手（3 条命令 / 常见故障 / 同步与发版） |

## 修改的上游文件

| 文件 | 改动说明 | 同步时处理 |
|---|---|---|
| `vite.config.ts` | dev 代理目标改为读 `EBK_DEV_PROXY_TARGET` 环境变量（默认仍 `http://127.0.0.1:8080/`，不破坏非容器开发），用于容器内把 `/api` 代理到 `backend` 服务 | 冲突时以上游为准，重新应用「代理目标 env 变量」这一处改动 |
