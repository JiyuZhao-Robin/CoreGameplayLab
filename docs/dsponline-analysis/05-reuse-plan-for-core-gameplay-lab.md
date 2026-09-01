# CoreGameplayLab 复用方案

## 1. 当前匹配关系

CoreGameplayLab 已经拥有正确的基础边界：

| DSPONLINE | CoreGameplayLab |
| --- | --- |
| `GameState` | `SpaceGameState` |
| `commitGame()` + engine commands | `Game.*` + `GameStateTransaction` |
| `engine.ts` | `SimulationEngine` + `LogisticsEngine` |
| content records | `data/content.json` + `ContentDatabase` |
| simulation projection | `Game` 查询 / UI projection |
| device UI state | `UiNavigationState` + UI cfg |
| local save store | `SaveRepository` / `LocalSaveRepository` |
| Factory Canvas | `IndustrialNetworkView` |
| semantic CSS tokens | `UiThemeTokens` |
| desktop workspace shell | `GameShell` |

因此不需要跨语言移植 TypeScript。应把 DSPONLINE 作为行为和不变量参考，在现有 GDScript 分层内实现。

## 2. 建议直接复用的思想

### A. 模拟阶段屏障

将当前 `SimulationEngine` 的 tick 明确写成阶段表：

```text
global_pre
  -> location_local[]
  -> deterministic_merge
  -> global_post
  -> metrics/events
```

即使现阶段单线程，也先建立边界。以后若引入 WorkerThread 或分区模拟，不需要重新定义规则顺序。

验收：

- 同一初始状态、命令序列和步长得到完全相同状态哈希。
- 不同 location 遍历顺序不改变结果。
- 全局物流只在 merge 后结算。

### B. 权威状态投影

不要让 `main.gd` 和各 Workspace 接收完整可写状态。新增只读投影：

- `ShellStatusProjection`
- `LocationResourceProjection`
- `ContextInspectorProjection`
- `IndustrialNetworkProjection`
- `WorkspaceProjection`
- `BlockerProjection`

投影携带 `state_revision`。UI 缓存只能影响绘制，不能写回 Domain。

### C. 命令 patch / intent

现有 `_command(label, callable)` 可演进为结构化 intent：

```gdscript
{
  "command_id": "...",
  "base_revision": 123,
  "kind": "SET_PRODUCTION_METHOD",
  "payload": {...}
}
```

先不必做通用 diff。为高价值命令建立稳定 DTO、预检结果和回执，可直接改善测试、重放、日志和未来并发。

### D. 画布分层

继续强化当前工业网络实现：

- topology revision 只在节点、端口、位置、线路变化时增加。
- runtime revision 处理库存、吞吐、状态和告警。
- 线路共享 draw layer，不为每条线创建重 Control。
- 空间索引负责 hover/click，视觉宽度与命中宽度分离。
- viewport + overscan 裁剪。
- 拖动画布时复用几何，只移动 transform。
- reduced motion 和暂停时停止装饰动画。

### E. 显式导航状态机

`UiNavigationState` 已统一桌面工作区、上下文和历史。下一步把 overlay/modal 纳入：

```text
route = workspace + subview + context
overlay = sheet | modal | null
back():
  close modal
  -> collapse/close sheet
  -> leave subview
  -> pop workspace history
  -> system map
```

不要继续增加 `*_open` 布尔值。

### F. 统一模态契约

为 Godot 建立一个 `ModalCoordinator`：

- 模态栈。
- exclusive input。
- 初始焦点策略。
- Tab/方向键限制。
- `ui_cancel` 只关闭栈顶。
- 关闭后恢复触发控件。
- 危险确认默认焦点在取消。
- 背景控件不可点击、不可聚焦。

### G. 保存证明

当前 `LocalSaveRepository` 已有 wrapper、checksum、临时文件和备份。可继续加入：

- `save_revision` 与 `parent_revision`。
- `state_revision`。
- 写后重读验证。
- 结构化 `SaveResult`，区分 quota/IO/checksum/schema。
- 大存档时异步序列化或线程化，但不在需要前引入复杂 Worker 模型。

## 3. 建议改造后复用

| DSPONLINE 机制 | 改造方式 |
| --- | --- |
| `SimulationLookupContext` | 转为 Godot 每 tick/每 revision 的只读索引对象 |
| production history | 使用固定采样窗口和环形缓冲，不复制字段名 |
| offline affine contract | 先证明 CoreGameplayLab 哪些系统可线性近似，再单独启用 |
| content pack fingerprint | 对 `content.json` 和启用包做 canonical hash |
| save catalog | 只有增加多槽/快照后再实现 |
| mobile route/sheet | Godot 移动版需要时采用同一状态机，不复制 DOM 结构 |
| command palette | 从 action registry 生成，不手写第二套命令定义 |
| workspace lazy loading | Godot 可按需实例化页面场景并缓存，而非照搬 JS chunk |
| cloud CAS | 仅在多设备同步需求确定后实现 |

## 4. 明确不要复用

### 不复制根组件

`App.tsx` 的集中协调思想可以保留，但不能产生第二个 10,000 行 `main.gd`。当前 `main.gd` 已约 3,900 行，应继续拆为：

- `UiRuntimeCoordinator`
- `WorkspaceRouter`
- `ContextInspectorController`
- `IndustrialNetworkController`
- `NotificationCenter`
- `ModalCoordinator`
- 各 Workspace Scene/Controller

### 不复制整块模拟文件

DSPONLINE 的 `engine.ts` 用一个文件保证了规则集中，但 CoreGameplayLab 已有更清楚的 `SimulationEngine`、`LogisticsEngine`、`EconomyPlanner` 和 requirement/modifier 模块。只移植阶段、不变量和测试 oracle。

### 不复制 CSS 或资产

当前 `UiThemeTokens` 已采用相近语义。继续维护原创 Godot Theme、图标和布局。不要导入 DSPONLINE 的 CSS、Logo、截图、glyph、品牌或文本目录。

### 不复制旧本地化桥

CoreGameplayLab 的 `I18n.t/core/content` 应成为唯一入口。`inline()` 兼容替换也应逐步收敛，不能继续扩大。

### 不复制超前基础设施

账号、邮件、排行榜、双区域部署、Electron IPC、Android Keystore 和云端归档不是当前单机核心循环的必要条件。提前移植会把研发资源从玩法正确性转向运维。

## 5. 推荐实施顺序

### 阶段 1：建立状态与模拟合同

1. 为每个 tick 阶段命名并写测试。
2. 生成 canonical state hash 测试工具。
3. 建立 location-local 结果 DTO 和稳定合并器，即使暂时串行。
4. 将 `progress_ratio`、blocker 和 operating status 从 UI 重算迁回领域查询。

完成标准：现有存档、经济和 UI 测试全通过；不同分区顺序状态哈希一致。

### 阶段 2：拆 UI 协调器

1. 把 overlay/modal 纳入 `UiNavigationState`。
2. 提取 `ModalCoordinator`。
3. 把 Inspector 数据构造提取为 projection。
4. 把工业网络交互状态从 `main.gd` 提取到 controller。
5. 每个 Workspace 独立场景和刷新契约。

完成标准：`main.gd` 不再包含具体页面业务公式；Back、焦点和 modal 有独立测试。

### 阶段 3：画布扩展性

1. 明确 topology/runtime revision。
2. Edge layer 使用批量几何缓存。
3. 建立节点/线路空间索引。
4. 增加可见节点压力与 LOD hysteresis。
5. 建立 100/500/1000 节点基准。

完成标准：暂停和运行状态下，拖拽、缩放、选择、连线均不触发全图重建。

### 阶段 4：存档韧性

1. 增加 revision/parent revision 和写后重读。
2. 保存失败返回结构化原因。
3. 增加异常中断、临时文件、备份损坏和 schema migration 测试。
4. 评估是否需要命令日志；只有真实丢档窗口存在时才实现。

完成标准：任一写入阶段失败后，主存档或备份至少有一个可验证版本。

### 阶段 5：离线加速

1. 先保留与在线完全相同的事件边界模拟。
2. 用真实长局测试定位耗时系统。
3. 只为可证明稳定的生产链建立宏观合同。
4. 对库存、物流、研究、项目和终局分别定义硬门禁。
5. 快速候选必须重载并与摘要校验后才能提交。

完成标准：随机生成和黄金存档上的快/精确差异在书面容差内；不确定系统只少发收益，不多发。

## 6. 具体文件落点

| 建议 | CoreGameplayLab 主要文件 |
| --- | --- |
| 模拟阶段与稳定合并 | `src/core/simulation_engine.gd` |
| 物流屏障与索引 | `src/core/logistics_engine.gd` |
| 命令 DTO / 回执 | `src/application/game.gd`、新 command 模块 |
| 状态 revision/hash | `src/core/game_state.gd`、`game_state_transaction.gd` |
| 只读投影 | 新建 `src/application/projections/` |
| 导航/overlay/back | `src/ui/ui_navigation_state.gd` |
| UI 拆分 | `src/ui/main.gd`、`src/ui/components/` |
| 主题与语义状态 | `src/ui/ui_theme_tokens.gd` |
| 存档 revision/验证 | `src/infrastructure/local_save_repository.gd` |
| 内容 fingerprint | `src/core/content_database.gd` |
| 可复现实验 | `tests/`、`artifacts/test-results/` |

## 7. 验收矩阵

### 领域

- 在线 1x、10x 与离线使用同一事件顺序。
- 资源守恒、预留、在途、安装、消费和损失账本闭合。
- 同一状态和命令序列哈希一致。
- UI 不能直接写 `Game.state`。

### UI

- 1366×768、1920×1080、2560×1440。
- English、zh-CN。
- 鼠标、键盘、手柄和触控目标。
- running、waiting、blocked、complete。
- reduced motion、左右栏折叠、modal stack 和 Back。
- 100/500/1000 节点画布。

### 存档

- 正常保存、写入中退出、临时文件残留、主文件损坏、备份损坏。
- schema 向前迁移和未知未来 schema 拒绝。
- checksum、revision 和 parent revision。
- UI preference 与玩法存档相互独立。

## 8. 优先级结论

最高价值的五项是：

1. 模拟阶段屏障与确定性合并。
2. Inspector/Workspace 的只读投影。
3. `UiNavigationState` 扩展为 route + overlay。
4. 工业网络 topology/runtime 双 revision。
5. 存档 revision + 写后重读证明。

这些改动直接服务当前 CoreGameplayLab，且不引入 DSPONLINE 的 React、云端和发布复杂度。

