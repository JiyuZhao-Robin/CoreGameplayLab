# DSPONLINE UI 参考审计

审计日期：2026-08-28  
参考项目：`D:\Projects\DSPONLINE`  
方式：Coordinator 与三个独立 Agent 只读检查；未修改、未构建、未向参考仓库写入产物。

## 结论

DSPONLINE 最适合作为信息架构和交互语言的参考，而不是代码或资产来源。本项目采用它的“工业控制台、中央工作区、上下文检查器、语义状态、渐进式指引和多尺寸截图门禁”原则，并在 Godot 中重新实现。React、React Flow、CSS、品牌、图标、截图、内容目录和游戏资产均不复制。

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

本项目采用：

- 顶栏只放时间、速度、地点、能源、物流告警、建设、研发和巨构状态。
- 左栏固定 11 个核心入口；锁定功能仍显示条件。
- 中央为当前工作区。
- 右栏由当前 location/entity/blocker 驱动，不再作为静态库存摘要。
- 底栏统一承载告警、时间线、任务和 Suggested Next Step。
- 1920×1080 为基准；1366×768 收缩侧栏，优先隐藏次要字段而非缩小正文。

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

1. 统一 `UIState` 表达 active workspace、selected context、overlay/modal，不再增加互斥页面布尔值。
2. 统一语义 Theme 和共享组件，页面不得各自发明颜色、间距、按钮风格。
3. 所有玩法动作必须到 Domain Command；所有规则数字来自 Query/Simulation。
4. Context Inspector 和 Diagnostics 共用结构化 BlockerInfo。
5. Guidance 必须有 `guidanceId`、真实 reason、navigation target、resolution type。
6. 系统地图和大型列表使用脏标记/快照，隐藏页面不高频刷新。
7. 先满足桌面 1366×768–2560×1440，再为未来移动布局保留状态机边界；不把 React 移动实现照搬进当前阶段。
