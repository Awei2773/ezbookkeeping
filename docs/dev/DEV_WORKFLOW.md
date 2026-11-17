# ezBookkeeping 二次开发工作流

> 本文档面向在 `feat/local-dev` 分支上做二开的团队。所有示例基于 v2.1.1 基线
> （上游 main = `9d695811`）实测代码结构。涉及命令均在 Docker 容器内执行，
> 不依赖宿主 Go/Node。

---

## 0. 分支铁律（先于一切）

- `main` 只做上游镜像，**只允许 `git merge --ff-only upstream/main`，禁止任何直接提交**。
- `feat/local-dev` 是二开主线，一切改动最终汇入这里。
- 功能分支 `feat/<功能名>` 从 `feat/local-dev` 检出，改完 `merge --no-ff` 回来再删。
- 版本只打 git tag（`my/v<上游版本>-<序号>`），**禁止改 package.json 的 version**。
- 每次 merge 上游必须 `--no-ff`，commit message 写 `sync: upstream vX.Y.Z`，
  这样 `git revert -m 1` 能整体回滚一次同步。
- **写代码前先 `git branch --show-current` 自证在 `feat/local-dev`**，不在就切过去。

---

## A. 代码地图（一句话职责）

| 目录 | 职责 |
|---|---|
| `cmd/` | 入口与命令注册。`webserver.go` 注册**全部** HTTP 路由；`database.go` 是 Sync2 建表清单；`initializer.go` 是启动装配（读配置→初始化 datastore→日志→定时任务） |
| `pkg/api/` | HTTP 处理器（controller 层）。每个 `XxxApi` 结构体挂一批 handler，方法签名 `func(c *core.WebContext) (any, *errs.Error)` |
| `pkg/services/` | 业务逻辑层（account/transaction/user/token 等），被 api 调用，内部再调 datastore |
| `pkg/datastore/` | 数据访问层（xorm 封装），`SyncStructs` 即 `Sync2` 建表入口 |
| `pkg/models/` | 数据模型：xorm 结构体（`xorm:"..."` 标签定义列/索引）+ 请求/响应 DTO（`json:"..."` 标签） |
| `pkg/converters/` | 各种账目导入/导出格式解析器（ofx/csv/excel/wechat/alipay 等），按 `converter` 接口注册 |
| `pkg/settings/` | 配置层：读 `conf/ezbookkeeping.ini`，支持 `EBK_<节>_<项>`（大写）环境变量覆盖，如 `EBK_SECURITY_SECRET_KEY`、`EBK_DATABASE_TYPE`、`EBK_USER_ENABLE_REGISTER` |
| `pkg/locales/` | 后端多语言文本（错误消息、邮件等） |
| `pkg/errs/` | 统一错误码体系（见 C 节） |
| `pkg/core/` | WebContext、Token 类型常量（`USER_TOKEN_TYPE_*`）、通用工具 |
| `src/views/desktop` | 桌面端 UI（Vuetify 4）页面与组件 |
| `src/views/mobile` | 移动端 UI（Framework7-Vue 9）页面与组件 |
| `src/models` | 前端数据模型（TS interface，与后端 DTO 对应） |
| `src/stores` | Pinia store：状态 + 调 `src/core/api.ts` 发起请求 |
| `src/core/api.ts` | 前端 axios 封装；`src/consts/api.ts` 定义 API 路径常量 |
| `src/locales` | 前端多语言文案（改文案先找这里） |

依赖方向（单向）：`cmd` → `pkg/api` → `pkg/services` → `pkg/datastore` → `pkg/models`。
`pkg/settings`、`pkg/core`、`pkg/errs`、`pkg/locales` 是全层公共依赖。

---

## B. 真实演练：给「交易」加一个字段

以给 `Transaction` 加一个 `Memo`（备注，`VARCHAR(255)`）为例，逐层走一遍。
**注意：这里只演示结构，验证时改动已回退，避免污染主线。**

### 1) 后端模型 `pkg/models/transaction.go`

`Transaction` 结构体（xorm 结构体）加字段：

```go
type Transaction struct {
    // ... 已有字段 ...
    Comment       string `xorm:"VARCHAR(255) NOT NULL"`
    Memo          string `xorm:"VARCHAR(255)"`   // ← 新增：列名 = 字段名 Memo
    // ...
}
```

同时更新两个请求 DTO 和响应 DTO：

```go
type TransactionCreateRequest struct {
    // ...
    Comment string `json:"comment" binding:"max=255"`
    Memo    string `json:"memo" binding:"max=255"` // ← 新增
}

type TransactionModifyRequest struct {
    // ... 同 create ...
}

type TransactionInfoResponse struct {
    // ...
    Comment string `json:"comment"`
    Memo    string `json:"memo"` // ← 新增
}
```

### 2) Sync2 建表影响（⚠️ 关键）

启动时 `initializer.go` 在 `auto_update_database = true`（默认）下，会走
`cmd/database.go` 里一长串 `SyncStructs(new(models.Xxx))`。对**已存在的表**，
xorm 的 `Sync2` 行为是：

- ✅ 会**新增缺失的列**、新增缺失的索引/唯一约束。
- ❌ **不会删除**表里多出来、但结构体里已没有的列。
- ❌ **不会修改**已存在列的类型/约束（缩列、改 NOT NULL 都不生效）。
- ✅ 不存在的表会整表创建。

所以「加字段」是安全的、静默的（无提示、无独立迁移 SQL）；但「删字段/改字段类型」
Sync2 不会帮你回退，需手动 `ALTER TABLE`。**因此铁律：任何 model 结构变更前，先备份
`data/` 目录**（SQLite 就是 `data/ezbookkeeping.db` 一个文件；MySQL/PG 则先 dump）。
验证命令：启动后 `sqlite3 data/ezbookkeeping.db '.schema ezbookkeeping_transaction'`（容器内）。

### 3) 服务层 `pkg/services/transactions.go`

若字段只是透传（存库→读回），services 通常无需改；若有业务逻辑（如「Memo 为空时
回填 Comment」），在 `CreateTransaction` / `UpdateTransaction` 里处理。

### 4) API 层 `pkg/api/transactions.go`

在 create / modify / list 三个 handler 里做「请求 DTO → model」和「model → 响应 DTO」
的映射，把 `Memo` 带上即可。handler 本身不改签名。

### 5) 前端

- `src/models/transaction.ts`：`TransactionInfoResponse` 接口加 `memo: string`，请求对象加 `memo`。
- `src/stores/transaction.ts`：提交/读取时透传 `memo`（多数情况无需改）。
- **双端 UI 各改一份**（见 D 节）：
  - 表单：`src/views/desktop/transactions/...` 与 `src/views/mobile/transactions/...` 各加一个输入框。
  - 列表展示：`src/views/desktop/transactions/...` 与 `src/views/mobile/transactions/...` 各加一列/一行。
- 文案：`src/locales/` 下各语言文件补 `memo` 的翻译。

---

## C. 真实演练：加一个接口 `GET /api/v1/xxx/list.json`

### 1) 接口约定

- 路径统一 `/api/v1/...`，**以 `.json` 结尾**（读接口 `GET`，写接口 `POST`）。
- 统一返回结构（见 `pkg/utils/api.go`）：
  - 成功：`{"success": true, "result": <你的数据>}`
  - 失败：`{"success": false, "errorCode": <int>, "errorMessage": "...", "path": "/api/v1/..."}`
- 处理器签名：`func (a *XxxApi) XxxHandler(c *core.WebContext) (any, *errs.Error)`，
  返回 `(nil, errs.ErrXxx)` 即失败，返回 `(数据, nil)` 即成功。
- 错误码：`errs.Error.Code()` = `Category*100000 + SubCategory*1000 + Index`。
  常规业务错用 `errs.NewNormalError(子类, index, http状态码, "message")`；参数错用
  `errs.NewIncompleteOrIncorrectSubmissionError(err)`。新错误码请登记到 `pkg/errs/` 对应文件。

### 2) 新建 handler

```go
// pkg/api/xxx.go
package api

type XxxApi struct {
    ApiUsingConfig
    // services...
}

func (a *XxxApi) XxxListHandler(c *core.WebContext) (any, *errs.Error) {
    // c.GetCurrentUid() 取当前用户
    // 调 services 拿数据
    return result, nil
}
```

### 3) 注册路由 `cmd/webserver.go`

在 `apiV1Route := apiRoute.Group("/v1")` 之后：

```go
apiV1Route.GET("/xxx/list.json", bindApi(api.Xxx.XxxListHandler, config))
```

最后一个参数是 `onlyAllowedTokenTypes ...core.TokenType`（可变参数）——**权限门禁**：
- 需要登录的普通接口：不传（默认允许任意已登录 token），或显式传 `core.USER_TOKEN_TYPE_NORMAL`。
- 只允许 MCP token：`core.USER_TOKEN_TYPE_MCP`。
- 只允许 API token：`core.USER_TOKEN_TYPE_API`。
- 例：`bindApi(api.Tokens.TokenGenerateAPIHandler, config, core.USER_TOKEN_TYPE_NORMAL)`。

`bindApi` 内部先 `middlewares.CheckCurrentTokenType(...)`，不通过直接 401。

### 4) 前端调用

- `src/consts/api.ts` 加：`export const XXX_LIST_API_URL_PATH = BASE_API_V1_URL_PATH + '/xxx/list.json';`
- 在对应 `src/stores/xxx.ts` 里用 `src/core/api.ts` 的封装 GET 它。

---

## D. 双 UI 改动规则

| 层 | 是否共享 | 说明 |
|---|---|---|
| `src/models`、`src/stores`、`src/core`、`src/lib`、`src/consts`、`src/locales` | **共享，改一份** | 数据与逻辑层双端复用 |
| `src/views/desktop` 与 `src/views/mobile` | **各改一份** | 两套完全独立的 UI 实现 |
| `src/components/base`、`src/components/common` | 共享 | 被两端引用的公共组件 |
| `src/components/desktop` / `src/components/mobile` | 各改一份 | 端专属组件 |

**规律**：改「数据形状/接口调用/文案」→ 只改共享层；改「页面布局/表单/展示」→
desktop、mobile 各改一份。**只改 desktop 忘了 mobile 是最常见的漏改**，改完用
`grep -rn 新字段 src/views` 自查两端是否都覆盖。

---

## E. 测试门禁

构建脚本 `build.sh` 会先跑测试/静态检查再编译。日常开发至少要过这三道（都在容器内跑）：

| 命令 | 作用 | 落点 |
|---|---|---|
| `go test ./...` | 后端单测 | 新增后端逻辑：`pkg/**/xxx_test.go` |
| `npm run test`（= `vitest run`） | 前端单测 | 新增前端逻辑：`src/**/__tests__/` |
| `npm run lint`（= `vue-tsc --noEmit && eslint . --fix`） | 前端类型+风格 | 无新增文件，确保不引入 TS 错误 |

> 实测结果见文末「首次验证结果」。

> ⚠️ `npm run lint` 带 `--fix` 会原地改文件，跑完记得 `git status`，不要误提交自动修复。

---

## F. 上游同步 SOP（单独成节）

### 前置
1. 读 GitHub Releases，确认目标版本无 breaking changes（v2.x 历史出现过：配置节改名、
   API 字段类型变更、Token 权限收紧）。
2. **备份 `data/` 目录**（Sync2 会静默改表）：
   `cp -r data data.bak.$(date +%Y%m%d%H%M%S)`

### 命令序列
```bash
git fetch upstream
git checkout main
git merge --ff-only upstream/main          # main 永远快进对齐上游

# 确认 main 已是最新，再回到二开主线合并
git checkout feat/local-dev
git merge --no-ff main -m "sync: upstream vX.Y.Z"

# 冲突按下面优先级表处理 → 跑测试门禁 → 全绿后打 tag
go test ./... && npm run test && npm run lint
git tag my/vX.Y.Z-N
git push origin feat/local-dev my/vX.Y.Z-N
```

### 冲突处理优先级表

| 文件 | 原则 |
|---|---|
| `go.mod` / `package.json` | **以上游为准**，手动加回自己新增的依赖 |
| `go.sum` / `package-lock.json` | 接受上游版（`--theirs`），然后重新 `go mod tidy` / `npm install` |
| `conf/ezbookkeeping.ini` | **以上游为准**（我们的覆盖全在 `.env` / 独立配置，不改源文件） |
| `pkg/models/*.go` | **逐字段手工合并，最危险**；合并后必查 Sync2 影响（见 B 节） |
| `cmd/webserver.go` 路由 | **双方路由都保留**（我们新增的 `apiV1Route.XXX` 与上游新路由并列） |

### 同步后照单核对
维护 `docs/dev/CHANGELOG.md`（见下），记录自己改过的文件清单，每次同步后照单核对
有没有被上游改动覆盖/需要重新适配。

---

## 首次验证结果（本机实测，2026-11-17）

- `go test ./...`：✅ 全部通过（exit 0，所有包 `ok` 或无测试文件；`exchangerates` 需联网约 41s）
- `npm run test`：✅ 通过（14 个测试文件、**38685** 个用例全过，约 8s）
- `npm run lint`：✅ 通过（`vue-tsc --noEmit` 0 错误 + `eslint . --fix` 干净，exit 0）

> 说明：三项均在 Docker 容器内跑，未在宿主安装 Go/Node。前端 `npm run lint` 带
> `--fix`，跑完务必 `git status` 确认没有误改文件（本次实测无意外改动）。
