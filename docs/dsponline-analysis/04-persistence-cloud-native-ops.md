# DSPONLINE 存档、云服务、原生端与运维

## 1. 本地存档格式

当前游戏状态 schema 为 v47，外层 save envelope 为 v2。Envelope 记录：

- format version。
- mode、slot、kind、savedAt 和可选 reason。
- 持久化状态投影。
- 状态 checksum。

`saveProjection.ts` 明确剔除 Worker 私有缓存、UI 瞬态和可重建数据。`saveEnvelopeIntegrity.ts` 检查 envelope；`saveTransfer.ts` 定义 UTF-8 二进制、checksum 和 byte length；`saveFileCodec.ts` 负责文件导入导出。

## 2. 保存流水线

推荐的权威主存档路径：

```text
Simulation Worker exact checkpoint
  -> transferable ArrayBuffer
  -> save.worker
       hydrate exact state
       apply bounded UI overlay
       persistent projection
       canonical envelope v2
       checksum + SHA-256
       optional gzip
       catalog seed + binding proof
  -> authoritativeSavePersistence.worker
       verify proof/binding
       verify writer fence
       compare expected revision
       preserve backup
       IDB transaction
       readback verification
  -> proof receipt
```

重要不变量：

- UI 线程不回退为大存档 JSON stringify/parse。
- ArrayBuffer ownership 会显式转移并在响应中归还。
- Worker 超时或崩溃后若所有权丢失，调用方必须重新申请 checkpoint。
- payload proof 绑定未压缩正文、传输编码、压缩正文、状态 checksum 和 catalog seed。
- 写入前检查单写者 fencing token 和 expected revision。
- 成功不是“transaction complete”就结束，还要回读校验。

兼容路径 `saveGame()` / `saveVerifiedPayload()` 仍存在，用于较小状态、导入和旧环境；新主流程通过 `saveGameVerifiedFromStateTransfer()` 或 `saveGameVerifiedFromEnvelopeTransfer()`。

## 3. IndexedDB 与降级

`localSaveStore.ts` 使用：

- DB：`dsp-idle-network.local-saves`
- schema version：2
- object store：`records`
- backend：IndexedDB、localStorage、memory

IndexedDB 保存正文、catalog、revision、冲突副本和恢复数据。内存只保留极少 raw payload，目录模式主要使用摘要，避免启动时把所有大存档常驻主线程。

自动快照上限为 2。空间压力时先清理可删除自动快照，受保护快照、手动槽和冲突副本不应被静默删除。Storage API 可报告 quota、persistence 授权和压力等级。

## 4. 多标签页单写者

`localSaveCoordination.ts` 定义：

- 15 秒 writer lease。
- 5 秒 heartbeat。
- session-scoped writer ID。
- fencing token。
- `navigator.locks` 锁名。
- BroadcastChannel 和 storage event。
- 每个 save key 的 revision。
- conflict candidate/persisted 双副本。
- 页面切换 continuation marker。
- quota/生命周期紧急镜像。

次要标签页进入只读。租约过期后新标签可接管，但旧标签的 fencing token 无法继续提交。若 CAS 发现 base revision 改变，候选不会覆盖新存档，而是进入冲突保存并要求用户选择。

## 5. 运行时恢复日志

普通自动存档不足以覆盖“Worker 已接受命令但主存档尚未写入”的窗口，因此另有 durable runtime recovery：

- checkpoint 保存精确状态、identity、SHA-256 和 base primary identity。
- pending intent 在命令发给模拟 Worker 前落盘。
- Worker 确认后 intent 转为有序 journal operation。
- journal 包含 command、模拟秒、墙钟秒、registry 和 revision。
- 达到操作数、模拟秒或命令上限后滚动新 checkpoint。
- head 采用分代记录，先 stage、验证，再原子发布。
- 腐坏 head 被隔离，不允许部分记录继续重放。

启动时 `simulationRuntimeStartupRecovery.ts`：

1. 验证选择的主存档 identity。
2. 读取可恢复 generation。
3. 把 checkpoint 和 journal 交给模拟 Worker。
4. Worker 顺序重放并报告进度。
5. 生成新 checkpoint/identity 或分块 UI projection。
6. 保存新的权威主存档。
7. rebase 或清除已吸收日志。

重放中任何失败都会使 Worker runtime 失效，必须用精确 checkpoint 重新 bootstrap。

## 6. 云存档客户端

`cloud.ts` 提供：

- 注册、登录、验证、密码重置和会话管理。
- 四个槽位，normal/speedrun 两种模式。
- 本地/云端/marker 三方比较。
- expected revision 冲突保护。
- 容量预检。
- gzip 上传和受限 raw fallback。
- 不确定响应后的 operation receipt / metadata 再确认。
- 历史恢复和删除。
- 排行榜、速度跑、公开空间站、反馈和错误上报。

同步状态不是只比较时间戳，而是：

- 本地 state checksum。
- 云 revision、payload checksum 和 state checksum。
- 上次同步 marker。

由此区分 empty、local-only、cloud-only、synced、local-newer、cloud-newer、conflict 和 unbound。

## 7. 云 API 服务

`server/index.mjs` 的 API 路由大类：

| 类别 | 路由 |
| --- | --- |
| 运行状态 | `/api/health`、`/api/ready`、`/api/public-status`、`/api/metrics` |
| 账号 | register、login、verify、forgot/reset password、logout |
| Web 会话 | migrate、status |
| 安全 | sessions、revoke、password、email、security-events |
| 账号数据 | export、archive export/import、legacy JSON import、delete |
| 云存档 | quota、current、history、upload、restore、delete |
| 社交 | station profile/publish/visibility/favorite/signal |
| 排行榜 | normal、me、speedrun submit/list、visibility |
| 运营 | analytics、presence、feedback、errors、admin review/prune |

所有请求先由 `http-route-policy.mjs` 选择最窄 body capability，再由 `http-security.mjs` 检查 method、重复 header、Origin、Content-Type、Content-Encoding、Content-Length、自定义头和 DTO 深度/节点/字节上限。

## 8. 服务端持久化

### 原子状态

`AtomicStoreBase` 把一次请求视为事务：

- clone 当前内存状态。
- 执行业务变更。
- 建立 runtime-state delta 和 payload 变更计划。
- 在单一 SQLite transaction 中提交。
- 成功后才替换内存快照。
- 失败保持旧状态。

### 云正文去重

`cloud-payload-store.mjs` 对正文计算 SHA-256：

- `cloud_save_payloads` 保留原有复合主键兼容。
- 大正文写入 `cloud_save_payload_blobs`。
- payload 行可存一个带 checksum/size 的受控 alias。
- 读取时验证 alias、blob 大小、UTF-8 和 checksum。
- 删除 revision 后只垃圾回收无引用 blob。

### 运行态拆分

`runtime-state-persistence.mjs` 将玩家、service daily、analytics visitor/session/daily 拆为有界记录。普通业务提交会同时协调 `app_state`，高频 presence/analytics 可只更新相关记录。启动时校验表结构、版本和 fingerprint。

### 索引

`runtime-indexes.mjs` 为用户查询、会话、排行榜、空间站和活动建立可重建索引。索引只加速查询，不成为唯一事实来源。

## 9. 账号和安全

- 密码使用 `scrypt` 派生并保存 salt/hash 参数。
- token、操作 token 和公开 ID 使用安全随机数。
- session 服务端保存 token hash，不保存明文。
- Web 可从 Bearer 迁移到 `__Secure-` Cookie。
- Cookie 写请求要求同源 Origin、`Sec-Fetch-Site` 和 HMAC 派生 CSRF token。
- 安全比较使用 `timingSafeEqual`。
- 登录、重置、会话撤销和账号操作记录安全事件。
- 反馈诊断经过字段投影、字符串截断和敏感 key 过滤。
- 上传先限制压缩体与解压体，再验证 envelope、schema v1-v47、字段合同和 checksum。
- 排行榜从服务器检查过的主存档重新计算，不信任客户端提交分数。

## 10. 账号归档

账号归档是 ZIP v2，包含 metadata、账号信息、云存档和历史。服务端流式生成，客户端可：

- Web：Blob 下载。
- Electron：主进程直接流到用户选择的文件。
- Android：专用插件写缓存文件并通过 FileProvider 分享。

导入分 preview 和 confirm：

- 先检查归档格式、完整性、用户绑定、配额和覆盖范围。
- 使用 import guard 和确认标记避免误覆盖。
- 大文件由专用 Worker/线程处理。
- 安装存档后要求排行榜重新验证。

## 11. PWA

PWA 只在生产 Web 根路由注册。build ID 写入 Service Worker URL，确保新页面能明确安装新 Worker，而不是永远沿用旧脚本 URL。

更新状态区分检查中、最新、已下载待重启、网络不可用、版本检查失败和稳定版回退。canary/previous 路由不注册正式根 scope。Service Worker 测试覆盖缓存版本、导航回退和更新生命周期。

## 12. Electron

安全设置：

- `contextIsolation: true`
- `nodeIntegration: false`
- `sandbox: true`
- 只加载本地 file 或开发源。
- 新窗口拒绝，外链只允许 HTTPS 并交给系统浏览器。
- IPC 校验 sender、method、path、origin、body size、response size 和 request ID。

大云请求通过 `MessagePort` 以 1 MiB chunk 双向流动，每块需要 ack，并支持取消和 watchdog。主进程拥有真实 HTTPS 目标，renderer 不能任意访问本地文件或 Node API。

应用还处理单实例、窗口位置、字体缩放、自动更新、更新前保存和账号归档下载。

## 13. Android

Capacitor 配置：

- `https://localhost` WebView origin。
- 禁止 cleartext 和任意导航。
- 生产关闭 WebView debug/log。
- 不安装通用文件系统插件。

`DspSecureSession`：

- 首次登录拿到的 Bearer token 被迁移到 Android Keystore AES-GCM。
- WebView 只保存随机 handle。
- 密文绑定 format version、handle 和 HTTPS origin 作为 AAD。
- 请求前 native bridge 将 handle 解出 token，响应后按协议更新或清除。
- Keystore 不可用时可使用仅进程内 volatile fallback。

导出由 `TextExportPlugin` 和 `AccountArchivePlugin` 提供窄能力。FileProvider 只暴露专用缓存路径，不能枚举任意应用文件。

## 14. 部署与发布

`deploy/` 覆盖：

- systemd API、handoff proxy、preflight、健康检查和定时任务。
- Nginx 主站、API、香港/上海节点、下载页和旧域名迁移。
- SQLite 在线快照、加密备份、异地备份和恢复演练。
- immutable release 目录、active symlink 切换和回滚。
- writer lock，防止两个 API 实例同时写。
- release manifest、ready probe、node health 和备份证据。

发布切换脚本先准备候选、验证源码和包布局、备份、启动候选、探测 readiness，再原子切换 active。失败路径保留旧版本并产生可审计证据。

## 15. 复用警告

CoreGameplayLab 当前是本地 Godot 单机游戏，不需要直接复制完整账号、云端、Electron 或 Android 网络桥。可复用的是：

- envelope + canonical checksum。
- 临时文件写入、fsync/关闭、原子替换和上一版备份。
- revision 与 expected-parent。
- 恢复日志的“意图先落盘、确认后提交”思想。
- 真实大存档与异常中断测试。

只有在确实加入多设备云同步后，才值得引入 CAS、operation receipt、内容寻址正文和账号归档。

