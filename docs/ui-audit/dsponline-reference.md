# DSPONLINE UI 参考审计

审计日期：2026-08-28  
参考项目：`D:\Projects\DSPONLINE`  
方式：Coordinator 与三个独立 Agent 只读检查；未修改、未构建、未向参考仓库写入产物。

## 结论

DSPONLINE 最适合作为信息架构和交互语言的参考，而不是代码或资产来源。本项目采用它的“工业控制台、中央工作区、上下文检查器、语义状态、渐进式指引和多尺寸截图门禁”原则，并在 Godot 中重新实现。React、React Flow、CSS、品牌、图标、截图、内容目录和游戏资产均不复制。

## 2026-08-31 用户方向更新

Core Gameplay Lab 的正式 UI 布局以 `D:\Projects\DSPONLINE` 为主要参考。仓库内 `UI-reference/` 的 Upload Labs 图片降为非规范历史材料，不再决定 Shell、导航、页面卡片、弹窗、科技树或检查器布局。科技树采用用户确认的横向拓扑语法：可平移/缩放画布、矩形项目节点、真实前置依赖连线、节点选择驱动 Context Inspector；所有节点和动作仍来自 Helios 的权威研究项目与领域命令。

该决定不允许直接复制 DSPONLINE 的 React/CSS、品牌或资产；Godot 实现继续使用本项目自己的语义 token、内容、本地化与自动化测试契约。

参考仓库在审计开始前已有未提交删除：`LICENSE`、`NOTICE`、`PRIVACY.md`、`README.en.md`、`README.md`。本次未触碰这些状态。

## 结构与权威边界

DSPONLINE 使用 React 19、TypeScript 6、Vite、React Flow，并覆盖 Web/PWA、Electron 和 Android。关键分层为：

- `src/game/`：领域状态、内容、命令、查询、模拟 Worker、存档。
- `src/components/`：桌面工作区、检查器、导航、弹窗和引导。
- `src/components/mobile/`：独立移动 Shell、导航、Sheet 和移动检查器。
- `src/hooks/`：响应式、输入、主题和性能策略。
- `src/i18n/`：语言上下文和目录。
- `tests/e2e/`：游戏流程、分辨率、本地化和可访问性验证。

可采用的边界：

```text
权威 GameState / Simulation
        ↓ query/projection
UI snapshot / view model
        ↑ player intent
Domain command gateway
```

写操作大多通过统一提交边界进入领域命令；呈现缓存不写回权威状态。当前项目延续这一原则，UI 不持有经济公式，不直接改库存、项目、科研、舰船、物流或巨构状态。

不可采用的结构：DSPONLINE 的 `App.tsx`、`engine.ts` 和 `styles.css` 均已成为超大文件；部分组件读取完整 `GameState` 并在 UI 内遍历全局状态。Godot 实现应拆为小型工作区、投影查询、统一命令入口和单一 UI 导航状态。

## 可采用的桌面布局

参考布局是高密度生产工作台：顶部全局状态、左侧资源/导航、中央画布、右侧 Context Inspector、底部命令或事件区域。左右侧栏可独立折叠，中央工作区实际扩展，并保留选择和滚动位置。

第一批 Godot 重构已经采用：

- 顶栏只放时间、速度、地点、能源、物流告警、建设、研发和巨构状态。
- 左栏显示当前地点资源、仓储、主要库存与当前 Guidance，并可独立折叠。
- 中央上方承载 11 个稳定的核心入口；锁定功能仍显示条件，下方为当前工作区。
- 右栏由当前 location/entity/blocker 驱动，不再作为静态库存摘要。
- 底栏统一承载当前工作区、Back、告警、时间线、任务和 Suggested Next Step。
- 1920×1080 为基准；1366×768 可折叠侧栏，并使用原生像素布局，优先释放中央空间而非缩小正文。

## Context Inspector 与下钻

DSPONLINE 的 Inspector 会根据无选择、单实体、多选或线路上下文切换。其有效优先级为：

1. 状态和阻塞原因。
2. 当前行为、实际进度与吞吐。
3. 输入、输出、库存和需求。
4. 高频解决动作。
5. 高级配置。
6. 危险动作。

当前项目采用相同问题导向：任何核心 blocker 都必须显示 `What / Why / What can I do / Where do I go`，并带结构化导航目标。无选择时显示当前地点摘要和下一步，而不是空白面板。

## Guidance 与操作反馈

可采用的模式：非模态任务教练只显示阶段、当前目标、真实卡点和一个主要动作；完成条件读取领域状态，而不是记录“按钮点过”。交互反馈分为短暂 Notice、持久 Alert、显式阻断 Dialog，不用一种弹窗承担全部职责。

本项目不采用一次弹出多页教程；First-Time Flow 继续使用：目标 → 玩家操作 → 即时反馈。

## 视觉语言与 Token

DSPONLINE 使用克制的暗色工业控制台：低圆角、细边框、低饱和表面，以及青色交互、绿色成功、黄色警告、珊瑚危险、蓝色信息。参考意义在语义分工，不在具体色值。

Godot 侧收敛为共享 token：

```text
surface_canvas / surface_panel / surface_raised
text_primary / text_secondary / text_muted
border / focus
status_running / status_info / status_warning / status_critical
spacing 4 / 8 / 12 / 16 / 24
radius 4 / 6 / 10
```

状态不能只靠颜色；同时使用状态文本、图标/形状、描边和原因。正文中英文不得沿用参考项目常见的 7–10px 小字号。

## 2D 地图和进度视觉

可采用：

- 地点/设施节点按类别使用局部 accent，不整卡高饱和着色。
- 可见线路和命中区域分离。
- 路线状态用线型、颜色和文本共同表达。
- 小地图或系统地图低频刷新，避免每帧重建。
- 紧凑节点只展示名称、状态和主要流量；详情交给 Inspector。
- 所有长期进度同时显示进度条、数值和状态文字。

不可采用：React Flow/DOM/CSS 实现，以及参考项目的品牌、物品 glyph、图标和截图资产。

## 舰船装配图决策（2026-08-31）

舰船制造不依赖 2D/3D 舰船模型作为主要表达。正式船厂界面采用可平移、缩放的空白装配画布，并明确采用 DSPONLINE 建筑编辑器的交互原则：玩家先从“舰船”Tab 拖入一个已解锁舰体，再从“零件”Tab 拖入任意已解锁组件；拖入仅创建草稿节点，系统绝不预先连线。连接完全由玩家从零件插头拖到舰体插槽完成。

舰体本身是具有固定空间拓扑的紧凑装配背板：小型舰体只暴露少量实体插槽，大型舰体按自身 `slot_layout` 提供更多且更齐全的插槽。插槽必须嵌在背板内部而不是排成边缘清单：中央圆形位固定表达必需的能源核心，引擎菱形位位于上方，底部方形位专用于护甲、护盾、船舱等船体结构，武器与传感器、采矿、维修等特殊插件接口分布在左右两翼。连线采用网格对齐的直角折线；未连接接口显示为灰色空心，连接后才切换为类型色和实心。只有方向、安装类型、槽位和形状均匹配且两端未被占用时才允许连接，行为类似现实主板接口防呆。画布草稿通过 `Game.ship_design_validation` 校验舰体唯一性、能源核心、安装族、模块解锁、接口占用、槽位、尺寸与装配容量；保存后成为 `SpaceGameState.ship_designs` 中的持久设计聚合。只有已保存且仍然有效的设计可以进入真实船厂队列，材料成本与最终生成舰船的模块清单均使用该设计，存档/读档保留节点位置和玩家连线。

DSPONLINE 在这里提供的是“Palette 拖拽创建草稿 → 端口实时校验 → 领域命令提交”的交互原则；Godot 节点、异形 glyph、数据结构和校验实现均为当前项目原创，没有复制参考项目的 React/CSS 或资产。

### 直接实现对照（2026-09-01）

本轮不再只做风格抽象，已只读核对 DSPONLINE 的 `CanvasBeltLayer.tsx`、`canvasTopology.ts`、`FactoryNodes.tsx` 与对应紧凑节点/端口样式，并把可观察的交互行为直接翻译到 Godot：

- 折线固定为“源端短引线 → 垂直到共享 Y 轨 → 水平主干 → 垂直到目标 → 目标端短引线”，短引线按两端水平距离在 12–34 px 内收敛。
- 自动路由检测源端与目标端之间的节点矩形；直达走廊被卡片阻挡时，在上、下候选轨道中选择离中点更近的一条，并保留 52 px 净空。
- 普通线路保持细线，选择态/类型态才加强；连接点保持小尺寸和低视觉重量。未占用舰体接口使用灰色空心 glyph，占用后才使用模块类型色并填实。
- 舰体插槽仍按本项目的舰船领域语义布置：中央能源核心、上方引擎、底部船体结构、左右特殊插件。DSPONLINE 没有这些舰船接口形状，因此三角/五边形/菱形/方形/圆形及其防呆规则仍由本项目实现。
- 基础暗色主题直接映射本地 `styles.css :root`：`#090d0c` 画布、`#111614` 表面、`#171d1b` 抬升面、`#2b3531/#41504a` 边框、`#62b5ae` 焦点青，以及相同的成功/警告/危险/信息状态色。
- 舰船装配画布进一步对齐 `factory-canvas`：`#0b100e` 底色、20 px 间距的 `#3c4743` 点阵、2 px 普通连线、`#131917` 节点主体、`#171e1b` 标题栏、6 px 圆角和克制的黑色投影。
- 本地 DSPONLINE 没有位图光标资源，而是使用 CSS 系统光标状态；Godot 对应使用画布拖动、节点移动、接口十字和不可用四种原生状态，不虚构一套不存在的光标图片。

这是对参考项目布局与路径行为的直接对照实现，不导入其 React 组件、CSS、素材、品牌或游戏数据。

## 工业网络动态实现审计（2026-08-31 补充）

本轮在可访问的只读副本 `/Volumes/T9/Developer/projects/DSPONLINE` 中进一步检查了工业网络动态实现。只记录可泛化行为，没有复制源码或资源：

- 线路只有在权威流量大于零时进入 active；流量/容量决定 packet 密度和节奏，而不是固定装饰跑马灯。
- 拓扑 revision 与 runtime flow update 分离；节点位置和端口变化才重建几何，普通数值更新只改变视觉签名。
- 大线路层使用批量 Canvas、viewport overscan、空间过滤、DPR 上限和 animation-frame 合并；拖动画布优先做整体位移，避免重复生成对象。
- 节点尺寸观察只更新 handle/port；生产进度用共享 visual clock，产出/到达是一次性 pulse，不把整卡永久点亮。
- 暂停时不继续重建领域流动画；编辑器 Hover、选择和输入仍工作。
- 参考节奏约为：控件 110–150 ms、workspace 约 170 ms、节点呼吸约 1.9 s、流动 dash 约 1.05 s。性能模式与 Reduced Motion 关闭连续动画。

Helios 将这些原则转化为一个 Godot `IndustrialNetworkEdgeLayer` 共享时钟、缓存 Bézier、非线性吞吐速度、拥堵降速、暂停/Reduced Motion 静止和 GraphNode 增量更新。具体时长、颜色、glyph、布局与数据模型均按 Helios 原创实现。

## 输入、焦点与返回

参考项目有统一 Workspace/Dialog 焦点契约：背景 inert、Tab 循环、Escape 策略、关闭后归还焦点；破坏性操作默认聚焦取消。当前项目应建立唯一 Modal/Back 层级，将 `ui_cancel`、Escape 和手柄返回统一处理。

首阶段桌面输入至少保证：

- 鼠标点击、hover、滚轮。
- 键盘焦点可见。
- Escape/Back 逐层关闭。
- Disabled gameplay action 可读取原因。
- 模态确认/取消及焦点恢复。

## 本地化

可采用：语言不改变实体 identity，不写入玩法存档；中英文、分辨率和关键状态交叉测试。

不可采用：参考项目的遗留 DOM 字符串/正则翻译桥。Godot UI 必须从稳定 localization key 取文案，参数由结构化消息插入，禁止渲染后替换文本。

## 截图与验证矩阵

参考项目的价值在于验证组合，而非其具体截图。当前项目的门禁为：

- 页面：System、Location、Industry、Inventory、Logistics、Construction、Research、Ships、Survey、Diagnostics、Megastructure。
- 分辨率：1920×1080、2560×1440、1366×768。
- 语言：English、zh-CN。
- 状态：运行、等待、阻塞、完成，以及巨构 0/20/40/60/80/100%。
- 检查：裁切、重叠、横向溢出、无法滚动、不可见控件、弱层级、错误状态色和本地化溢出。

## 许可与资产边界

参考仓库 HEAD 的许可为 PolyForm Noncommercial 1.0.0，并有独立商标和商业使用说明。即使用户拥有两个项目，本次也按最保守边界执行：只提炼设计原则，不复制代码、样式表、Logo、项目名、截图、反馈资产、内容名称或完整英文目录。所有 Godot UI、token、组件和测试在当前项目内独立实现。

## 明确不采用

- 超大根组件和几十个互斥布尔状态。
- 把完整 GameState 传给所有视图。
- UI 内重算领域聚合和生产公式。
- 21k 行全局样式与后期 `!important` 覆盖。
- 过小正文字号和只靠颜色表达状态。
- DOM/MutationObserver 本地化桥。
- 桌面布局等比压缩成移动布局。
- 将主题、侧栏、筛选等设备偏好写入玩法存档。

## 对 Core UI 实现的直接约束

1. `UiNavigationState` 已统一 active workspace、selected context、navigation history 与侧栏折叠；overlay/modal 仍是下一批迁移目标，不再增加互斥页面布尔值。
2. 统一语义 Theme 和共享组件，页面不得各自发明颜色、间距、按钮风格。
3. 所有玩法动作必须到 Domain Command；所有规则数字来自 Query/Simulation。
4. Context Inspector 和 Diagnostics 共用结构化 BlockerInfo。
5. Guidance 必须有 `guidanceId`、真实 reason、navigation target、resolution type。
6. 系统地图和大型列表使用脏标记/快照，隐藏页面不高频刷新。
7. 先满足桌面 1366×768–2560×1440，再为未来移动布局保留状态机边界；不把 React 移动实现照搬进当前阶段。
