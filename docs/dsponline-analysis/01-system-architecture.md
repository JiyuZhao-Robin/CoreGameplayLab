# DSPONLINE 系统架构

## 1. 运行拓扑

```text
浏览器 / PWA / Electron Renderer / Android WebView
                    |
                 main.tsx
                    |
          route + platform bootstrap
        /           |             \
 AdminDashboard  PublicStation   GameLauncher
                                  |
                             StartMenu
                                  |
                           FactoryRuntime
                                  |
               ReactFlowProvider + FactoryGame
                                  |
       UI intent -> command patch -> Simulation Worker
                                  |
                     projection / revision / proof
                                  |
                  save Workers -> IndexedDB
                                  |
                 HTTPS cloud API -> Node server
                                      |
                                    SQLite
```

### 入口职责

- `src/main.tsx:1-68` 在首次绘制前初始化主题、语言和平台标记；安装监控与分析；按 URL 懒加载管理后台、公开空间站或游戏入口；只在生产 Web 注册 PWA。
- `src/GameLauncher.tsx:1-74` 管理开始菜单、发行说明和一次游戏会话的装载。真正的工厂运行时被 `lazy()` 分块。
- `src/FactoryRuntime.tsx:1-28` 提供 React Flow 上下文，按需加载英文目录，然后挂载 `FactoryGame`。
- `src/App.tsx:1237-12698` 的 `FactoryGame` 是实际运行时协调器。它持有权威 UI 镜像、Worker 协议、存档生命周期、画布交互、工作区和跨端适配。

这个启动链使开始菜单不必预加载 12,698 行根运行时、React Flow 和全部工作区。`vite.config.ts` 又把 React、React Flow、游戏核心拆成独立 chunk。

## 2. 分层与权威边界

### 内容层

`src/game/content.ts` 提供内置物品、建筑、配方、科技和构造目录；`src/game/galaxy.ts` 提供持久化银河生成、行星环境和命名；`src/game/contentPacks.ts` 在加载存档前恢复声明式扩展目录。

内容 ID 使用字符串联合。定义用 `Record<ID, Definition>` 保存，并通过 `validateContentCatalog()` 和 progression audit 检查闭包。内容包不执行任意 JavaScript，只能声明物品、通用建筑、配方、科技、建筑安全覆盖和传送带等级。

### 状态层

`src/game/types.ts:1634-1693` 的 `GameState` 是持久化聚合根，当前 schema 为 v47。状态包含：

- 模式、版本、随机银河种子和累计时间。
- 当前行星、各行星托盘、实体、传送带和视口。
- 研究、手工制造、建设队列、制造中心自动化。
- 探索、行星角色、物流站、在途航线、系统空间站。
- 戴森云、戴森球工程、黑洞、时间扭曲和银河出口。
- 蓝图、画布区域和书签。
- 成就、战役、速度跑、生产历史和设置。

状态中既有领域真相，也有少量可持久化玩家布局。设备偏好逐步迁移到独立 local/session storage，不再全部写入玩法存档。

### 领域层

`src/game/engine.ts` 是最主要的领域模块。其导出函数既包含查询，也包含命令和模拟推进。多数玩家写操作采用：

```text
GameState -> domain function -> new GameState / structured result
```

实时模拟为了性能，在 Worker 私有的 `PersistentSimulationRuntime` 中原地修改记录；对外仍以 revision、projection、checkpoint 和 command patch 维持清晰边界。

### 命令层

UI 通过 `commitGame(updater)` 提交领域函数，不直接修改库存、配方、物流或研究字段。提交过程会：

1. 检查主存档保存期间是否允许编辑。
2. 计算命令后的候选状态。
3. 从旧状态和候选状态生成 `SimulationCommandPatch`。
4. 以 Worker 当前 revision 为 base revision 顺序发送。
5. 先持久化 durable intent，再交给模拟 Worker。
6. 接受 Worker projection 并更新 UI 镜像。
7. 在 revision 不匹配时请求 checkpoint/resync。

`src/game/simulationRuntimeProtocol.ts` 定义 patch、state transfer、identity 和序列化契约。数组记录采用有序 record patch，普通值采用路径 patch；空 patch 可被识别并跳过。

### 查询与投影层

`src/game/simulationProjection.ts` 从权威 Worker 状态生成 UI 所需的增量投影。投影支持：

- 默认当前行星范围。
- 延迟顶层字段同步。
- 全当前行星记录。
- 大型权威替换时分块传输。
- 可选工厂告警投影。

UI 镜像不等于权威状态。画布、统计和 Inspector 从镜像继续派生更窄的只读 view model。

## 3. 主线程与 Worker

### 实时模拟 Worker

`src/game/simulation.worker.ts` 保存唯一的 `PersistentSimulationRuntime` 和 `runtimeRevision`。请求类型包括：

- `advance`：应用可选命令并推进模拟。
- `checkpoint`：返回精确可转移状态。
- `sync-projection`：强制发布延迟顶层投影。
- `replay-durable`：从 checkpoint 重放持久化操作日志。

它还处理：

- 内容包 fingerprint 握手。
- full、delta、projection 三种返回协议。
- 大 checkpoint 的 base/entities/belts 分块。
- 多核行星阶段。
- 纯挂机/时间扭曲近似路径。
- revision 冲突后的 `needsResync`。
- 恢复失败后的 runtime invalidation，防止继续使用部分变异状态。

### 专用 Worker

| Worker | 职责 |
| --- | --- |
| `save.worker.ts` | 投影持久状态、生成 envelope、checksum、SHA-256、压缩和证明 |
| `authoritativeSavePersistence.worker.ts` | 验证证明、CAS/fence 写 IndexedDB、回读、备份 |
| `simulationRuntimeRecoveryPersistence.worker.ts` | 写恢复 checkpoint、pending intent、journal 和 head |
| `offlineSimulation.worker.ts` | 精确或快速离线结算、上传前离线推进 |
| `pureIdleMacro.worker.ts` | 长时间纯挂机校准、宏观推进、验证和终态 envelope |
| `multicoreSimulation.worker.ts` | 仅执行行星局部阶段 |
| `statistics.worker.ts` | 大量统计聚合 |
| `saveInspection.worker.ts` | 导入存档检查 |
| `saveSummary.worker.ts` | 槽位和快照摘要 |
| `localSaveCatalog.worker.ts` | 本地存档目录修复/构建 |

这不是“有耗时工作就丢给 Worker”的随意拆分。每个 Worker 都有明确的所有权、超时、取消、校验和失败语义。

## 4. 浏览器、桌面与 Android

同一套 Vite 资源运行在三个容器中：

- Web/PWA：浏览器 Fetch、IndexedDB、Service Worker。
- Electron：本地 `dist/`，sandbox + context isolation；云请求和归档下载通过窄 IPC 桥。
- Android：Capacitor WebView；云请求通过安全会话插件，导出通过专用只写插件。

构建期常量 `__APP_PLATFORM__` 决定原生入口，避免运行时同时装入全部平台代码。社区构建默认不获得官方 API 和更新地址，官方地址由受保护发布环境显式注入。

## 5. 服务端

`server/index.mjs` 是 6,201 行的单进程 HTTP API 组合根。它负责：

- 健康、就绪、公开状态和管理指标。
- 注册、登录、邮箱验证、密码重置和 Web Cookie 会话迁移。
- 会话管理、安全事件、账号导出/导入/删除。
- 云存档容量预检、上传、下载、历史、恢复和删除。
- 排行榜、速度跑、空间站发布、收藏和信号。
- 分析、在线状态、反馈和错误报告。
- 限流、请求体能力、CORS、安全头和原子持久化协调。

服务端依赖很小：Node.js、`better-sqlite3` 和腾讯云 SES SDK。SQLite 是同步 API，但写请求通过应用级队列、事务和 release writer lock 串行化。

## 6. 数据存储分层

服务端不是把全部运行状态简单写回一个 JSON：

- `app_state` 保留规范化总状态和回滚兼容边界。
- `runtime_state_records` 将玩家、在线、分析和日统计拆成有界记录。
- `cloud_save_payloads` 保留用户/槽位/revision 到 payload 的兼容映射。
- `cloud_save_payload_blobs` 按 SHA-256 存正文，alias 让重复 revision 共享内容。
- runtime indexes 为用户名、会话、排行榜、空间站等查询提供可重建索引。

当前文档与实现所述版本边界是：云 schema v8、SQLite layout v3；payload 子布局版本为 2，runtime-state persistence 版本为 1。

## 7. 代码组织质量

### 优点

- 领域逻辑有大量纯函数和确定性测试。
- 大状态跨线程传输有明确所有权，不在 UI 线程随意克隆。
- 保存、恢复、上传和发布都带校验、版本和回读。
- 浏览器、桌面、Android 的安全边界分别设计。
- E2E 使用真实工作流和大存档，不只做组件快照。
- CI 固定第三方 action commit，发布门禁生成 manifest、SBOM、provenance 和 attestation。

### 结构债务

- `App.tsx` 同时承担 application service、state machine、canvas controller 和 view composition。
- `engine.ts` 同时承担内容查询、命令、模拟、诊断和多核合同。
- `storage.ts` 同时承担 schema migration、离线结算、文件编解码、槽位、快照和保存调度。
- `server/index.mjs` 既是路由表又是业务服务和组合根。
- 超大 CSS 依靠全局选择器和后续覆盖，变更影响面难以局部证明。

## 8. 测试架构

仓库共有 332 个按名称识别的测试文件、88,800 行测试代码。其中 TypeScript/JavaScript 测试为 324 个、88,333 行、测试声明粗计约 2,503；另有 8 个 Android Java 测试、467 行。层次包括：

- Vitest：领域规则、迁移、投影、Worker 协议、性能合同。
- Node test：服务端、部署、备份、原生桥和发布工具。
- Playwright：游戏流程、移动端、分辨率、本地化、PWA、云存档和真实大存档。
- Android JUnit/instrumentation：协议、文件导出和 Keystore 会话。
- 基准：物流、线路、画布、多核、离线、上传检查和服务端索引。

`release-gate.yml` 固定源提交后执行类型检查、完整单测、服务端/运维/原生测试、依赖审计、Web 构建、关键 Playwright、PWA 生命周期、发布清单、SBOM 和 provenance 校验。
