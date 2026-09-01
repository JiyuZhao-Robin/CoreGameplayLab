# DSPONLINE UI 与交互

## 1. UI 总体形态

桌面端是高密度工业控制台：

```text
┌──────────────────── Top Status / Global Commands ────────────────────┐
│ Planet rail │                  Factory Canvas              │ Inspector │
│ Resources   │          nodes / belts / regions             │ Context   │
├─────────────┴──────────────── Workspaces ───────────────────┴───────────┤
│                      Construction Dock / notices                       │
└─────────────────────────────────────────────────────────────────────────┘
```

核心视觉不是营销页，而是连续操作工作台。UI 将全局状态、位置上下文、中央编辑、选择详情和命令区放在固定空间关系中。

## 2. 根组件职责

`FactoryGame` 从 `App.tsx:1237` 开始，持有超过一百个 React state/ref。主要职责包括：

- 权威 Worker 的 revision、pending request 和恢复。
- 自动存档、手动槽、快照、导入和云同步。
- 纯挂机、离线报告和时间扭曲。
- 桌面/移动导航与工作区开关。
- React Flow nodes/edges、选择、拖动、缩放和区域。
- 连线草稿、批量连线、端口命中和触屏长按。
- Canvas LOD、虚拟化、拓扑缓存和低帧率模式。
- 通知、声音、动画、任务高亮和 Inspector。

这种集中协调能保证所有动作经过一个提交边界，但维护成本已经过高。复用时应保留边界，不保留组件规模。

## 3. 桌面 Shell

### 顶栏

显示当前地点、模拟暂停/速度、关键经济与终局状态，并承载设置、命令面板、保存和菜单入口。低宽度时次要命令进入 overflow。

### 行星与资源侧栏

`PlanetNavigator` 和 `ResourceRail` 用于切换行星、查看托盘、库存、资源和局部状态。侧栏可独立折叠，中央画布实际获得空间，而不是仅视觉隐藏。

### 中央画布

React Flow 负责平移、缩放、节点选择和拖动；大批线路由 Canvas 层统一绘制。画布支持：

- 建筑放置与连续放置。
- 单选、多选、框选、批量移动和删除。
- 拖拽连线、点击连线和批量连线。
- 蓝图放置、旋转、镜像和重叠策略。
- 区域创建、移动、缩放和命名。
- Fit View、书签和小地图。
- 线路网络聚焦、查线和批量升级。
- 触控双指缩放、边缘自动平移和长按。

### Inspector

Inspector 根据上下文切换：

- 无选择：当前行星概览和建议动作。
- 单实体：运行状态、输入输出、配方、功率、升级和配置。
- 多实体：批量配方、锁定、增产、升级和删除。
- 单线路或线路网络：吞吐、容量、优先级、堆叠、路线和移除。
- 区域：名称、颜色、边界和删除。

有效信息顺序是“状态/阻塞 → 实际吞吐 → 输入输出 → 修复动作 → 高级设置 → 危险动作”。

### Construction Dock

建设面板按建筑族和解锁状态显示施工物。拖拽或点击进入放置模式；数量、线路等级和自动选择等在放置前固定。移动端使用独立 build sheet。

## 4. 工作区

| 工作区 | 主要职责 |
| --- | --- |
| `TechnologyWorkspace` | 科技树、当前研究、队列、无限科研 |
| `StatisticsWorkspace` | 生产/消费、线路、功率、趋势和定位 |
| `RecipeWorkspace` | 物品、配方、生产者/消费者和图鉴 |
| `StarMapWorkspace` | 恒星系、探索、殖民、距离和路线 |
| `BlueprintWorkspace` | 蓝图目录、变换、部署、导入导出 |
| `DysonPlannerWorkspace` | 轨道、层、节点、框架、壳和发射控制 |
| `CampaignWorkspace` | 章节、任务、奖励和引导 |
| `OperationsWorkspace` | 告警、物流、生产管理、设置、存档和账号 |
| `GalaxyWorkspace` | 排行榜、速度跑、云存档和账号入口 |
| `ConstructionCenterWorkspace` | 自动制造目标、队列和运行状态 |
| `SystemSpaceStationWorkspace` | 星系空间站建设和枢纽 |
| `OrbitalStationWorkspace` | 轨道站阶段、合同、展陈和公开资料 |
| `OfflineReportWorkspace` | 离线收益、损耗、限制和结算方法 |
| `TutorialWorkspace` | 可检索教程和情景说明 |

大工作区由 `lazy()` 动态加载，`WorkspaceFrame` 提供统一标题、返回和内容壳。

## 5. 画布渲染架构

### 拓扑与运行态分离

`canvasTopology.ts` 缓存：

- 实体拓扑签名。
- 端口占用。
- 线路 bundle。
- 线路自动避让中心。

`canvasRenderSnapshot.ts` 将稳定拓扑和最新运行时记录合并。库存、进度、告警变化不会强制重建全部 Node/Edge 对象。

### 线路层

`CanvasBeltLayer.tsx` 将大量线路批量绘制到 Canvas：

- 接收 topology revision 与 runtime flow signature。
- 使用 DPR 上限。
- 按 viewport + overscan 裁剪。
- 平移时优先复用整层位移。
- requestAnimationFrame 合并绘制。
- active flow 才运行动画。
- reduced motion、暂停和性能模式会停止连续动画。

`canvasLineBatch.ts` 将线路几何压成 typed arrays；`canvasBeltSpatialIndex.ts` 用网格索引做命中，避免逐线扫描。

### 节点 LOD

节点有 full、medium、compact 三档。自动模式带 hysteresis：

- 可见节点达到 140 进入 medium，低于 100 才退出。
- 达到 480 进入 compact，低于 360 才退出。
- 高密度下即使偏好 full，也有 1400/1800 的安全降级。

source、主选择、hover、focus、拖动节点、连接候选和定位目标可以临时提升细节。批量选择的其他成员保持简化，避免交互时突然挂载大量 DOM。

### 稳定几何

compact、medium、full 节点各有稳定尺寸。线路端点、裁剪、命中和 fit view 读取当前 presentation size，不能使用 React Flow 上一帧 measurement。没有可见节点时保留边界锚点供 Fit View 恢复，但不改变权威节点集合。

## 6. 连接交互

连接支持鼠标拖拽、触屏长按、点击源后点击目标和批量连续模式。连接开始时锁定：

- 源实体和端口。
- 物品。
- 自动或手动线路等级。
- 初始候选与提示状态。

端口命中使用独立空间索引和扩大命中区，视觉点可以很小而触控目标仍足够大。候选失败只显示本次原因，不污染此前有效候选。最终确认再次走同一领域原子校验。

## 7. 移动端

移动端不是 CSS 压缩版桌面端。`useMobileNavigation.ts` 定义：

```text
MobileRoute:
  factory | hub | workspace(id, subview)

MobileOverlay:
  sheet(id, snap) | modal(id) | null
```

关键行为：

- Bottom Nav 在 Factory、Hub 和主要入口之间切换。
- Build、Inventory、Inspector、Planet、Tools 使用 peek/half/full Sheet。
- Sheet 高度变化、子视图和工作区都写入 history marker。
- 浏览器/系统 Back 先降 Sheet、关 overlay、退 subview、退 workspace，最后才请求退出。
- `replaceModalWithWorkspace` 和 `replaceModalWithSheet` 避免历史中留下不可返回的中间状态。
- Canvas 工具有专门的移动模式和上下文栏。

这套显式状态机比多个 `isXOpen` 更适合移植到 Godot。

## 8. 模态与可访问性

`AccessibleDialog.tsx` 建立统一模态契约：

- `role=dialog/alertdialog` 与 `aria-modal`。
- 记录并恢复触发焦点。
- 初始焦点、取消优先和危险操作策略。
- Tab/Shift+Tab 循环。
- Escape 策略。
- 背景 inert 和 `aria-hidden` 快照恢复。
- document/body 滚动锁。
- 多模态栈，只允许最上层响应。
- pointer down/up 必须都在 backdrop 才关闭。

`GameDialogProvider` 将 confirm/alert 请求序列化，避免各组件自行创建不一致弹窗。

## 9. 主题与视觉 token

暗色基准位于 `styles.css`，亮色覆盖位于 `theme.css`。语义 token 包括：

- canvas、surface、raised、soft、inset、control。
- text、secondary、muted、disabled。
- border、strong border、focus。
- cyan/accent、green/success、yellow/warning、coral/danger、blue/info。

画布基准是接近黑绿的 `#0b100e`，节点表面 `#131917`，标题 `#171e1b`，网格点 `#3c4743`，焦点青 `#62b5ae`。圆角总体克制，面板多为 4-7px。

Vite 插件在构建时把 `styles.css` 的 px 字号改写为 `calc(px * --ui-font-scale)`；专项样式多数直接使用同一变量。

问题是样式总量很大：

- `styles.css` 24,634 行。
- `theme.css` 1,683 行。
- 移动端三文件合计 1,806 行。
- 另有空间站、图鉴、时间扭曲、存档、对话框等专项文件。

全局级联和主题覆盖之间存在显著耦合，适合提炼 token，不适合复制样式表。

## 10. 本地化

新路径通过 `AppLocaleProvider`、消息目录和稳定 key 提供中英文。英文大型目录按需加载，避免中文启动路径承担全部字典成本。

`legacyTranslations.ts` 仍包含旧字符串映射和 DOM 后处理兼容。它能快速补齐历史页面，但有以下缺点：

- 显示文本被当成 identity。
- 文案细微变化会破坏映射。
- MutationObserver/后处理增加运行时成本。
- 参数化、复数和上下文难以保证。

CoreGameplayLab 应继续使用稳定 key 和结构化参数，不应移植该兼容层。

## 11. UI 优点与问题

### 优点

- 画布在超大网络下仍考虑 DOM 数量、线路批处理和触控命中。
- Inspector 与领域状态紧密对应，阻塞原因可操作。
- 桌面和移动端共享领域命令但拥有独立导航。
- 模态、焦点和返回规则有专项测试。
- 真实大存档 E2E 覆盖 LOD、画布密度和存档生命周期。

### 问题

- 根组件状态爆炸，页面互斥关系不由统一桌面路由表达。
- `GamePanels.tsx`、`StartMenu.tsx` 等组件仍很大。
- 组件有时接收完整 `GameState` 并现场遍历。
- CSS 体积和覆盖关系使视觉回归成本高。
- 小字号较多，不适合直接用于 CoreGameplayLab 的可读性目标。
- 旧本地化桥与新消息目录并存。

