# Helios 工业网络 UI 设计与实现

日期：2026-08-31  
范围：`工业与建设 > 生产 > 网络视图`，单地点文明级聚合网络。

## 产品定义

本页面是一套“轨道工业运行控制台（Orbital Industrial Operations Console）”。它回答三个问题：资源从哪里来、当前经过什么真实工业对象、为什么没有到达下游。网络是权威 Simulation 的只读投影，不是传送带编辑器，也不创建生产或运输关系。

节点代表文明级聚合对象：

| 类别 | Domain 对象 | 首屏信息 |
| --- | --- | --- |
| Source | Extraction Network、永久采掘来源 | 可持续产能、实际产出、状态 |
| Production | Factory 内真实 Production Line、Production Device、Production Method | 实际/理论吞吐、利用率、输入、输出、首要 blocker |
| Buffer | 地点库存与 Storage Class | Available、Reserved、Inbound、Capacity、净变化、承诺需求 |
| Logistics | Route、Hub、在途 Shipment 的地点侧投影 | 方向、运输方式、实际/请求/容量、在途、拥堵 |
| Demand | Construction、Research、Shipbuilding、Maintenance、Megastructure 等 DemandSource | 产品、持续 rate 或 committed backlog、优先级 |
| Infrastructure | 能源、散热、结构和装卸支持包络 | 权威 constraint profile 与吞吐倍率 |

能源、散热和维护默认关闭线路图层，只在节点状态、Inspector 和可选 Service 图层出现，避免常驻“意大利面图”。一个 Factory 或一条聚合生产线是节点；单台机器不是节点。

## 端口与连接语义

端口同时使用形状、填充、文本和颜色：

- 方形：实体物资。
- 圆形：能源、散热、维护等服务。
- 三角形：项目需求。
- 菱形：信息、科研或控制。
- 实心：当前满足或存在有效连接。
- 空心：未满足、未连接或没有实际流。

连接固定为左输入、右输出。每条边携带 stable edge ID、source/target node/port、item/service type、actual flow、requested flow、capacity、in-transit、status、congestion 和 bottleneck 标记。正常、拥堵、断供、暂停和瓶颈分别使用稳定线、琥珀降速、低亮/断续、停止流动和最短链聚焦；标签只在足够缩放、Hover、选择或瓶颈模式显示。

工业网络 UI 不允许拖拽端口篡改运行中的物流关系。舰船装配画布是独立的设计编辑器例外：它允许玩家手工连接舰体与零件，但只生成可校验、可保存的 `ship_designs` 草稿/领域聚合，不直接移动库存或创建 Shipment；真正的材料消耗和舰船生成仍由船厂队列与 Simulation 完成。

## Helios 视觉语言

共享 `UiThemeTokens` 定义石墨黑/深海军蓝表面、低饱和细边框和以下语义色：

- 冷青绿：正常实体物料流和运行。
- 冷青/蓝：库存、物流和一般信息。
- Helios 金/橙：能源、建设、关键操作和需求。
- 紫蓝：科研、实验和特殊资源。
- 琥珀：受限、接近短缺、拥堵。
- 珊瑚红：阻塞和严重短缺。
- 灰蓝：暂停、未知和不可用。

节点宽度固定在有限的聚合规格，卡片使用低圆角、细边框和轻阴影；发光只用于选中、真实流动、严重状态和瓶颈。网格由 `IndustrialNetworkEdgeLayer` 程序化绘制，含主次网格并跟随 GraphEdit zoom/pan，未使用参考截图、位图背景或来源字体。所有类别和端口 glyph 均由项目内 CanvasItem 原创绘制。

## 动画状态表

| 状态 | 动画 |
| --- | --- |
| 实际流量 > 0 且游戏运行 | 一个共享视觉时钟沿 Bézier 方向移动 1–4 个短脉冲；速度对 flow 做对数压缩 |
| 高利用率 | 线宽与亮度适度增加 |
| 拥堵/饱和 | 琥珀色、脉冲速度降低，表示堆积而非“更快” |
| 零实际流量 | 不绘制流动脉冲，禁止假流量 |
| 游戏暂停 | 领域流动停止；Hover、选择和菜单仍可操作 |
| 正常运行节点 | 仅进度填充做约 2 秒轻微呼吸 |
| Warning/Critical | 静态边框、图标、文字和低频状态色，不持续抖动 |
| 数值变化 | 约 220 ms 显示插值；Domain 值本身不插值、不写回 |
| 自动整理/聚焦 | 340 ms 可中断二次缓出；用户平移立即取得控制权 |

每条边和每个节点都没有独立 Tween/Timer。共享边层时钟批量绘制连续动画；节点只消费同一个 visual time。100× 模拟只改变权威快照里的 rate，不提高 UI 刷新频率。

## Domain → Projection → UI

```text
SpaceGameState
  + SimulationEngine / EconomyPlanner / Logistics
       industrial_network_snapshot(location)
                         ↓ authoritative read-only snapshot
IndustrialNetworkProjection
  stable IDs + localized labels + graph topology + navigation/actions
                         ↓ immutable presentation dictionary
IndustrialNetworkView
  GraphEdit pan/zoom/selection/node drag
  IndustrialNetworkNode diff updates
  IndustrialNetworkEdgeLayer batch drawing
                         ↑ player intent
main.gd Context Inspector → existing Game.* command gateway
```

经济公式只存在于 Simulation/Planner。Snapshot 使用相同的生产周期、约束、库存、Demand Registry、Route service 和 bottleneck query；Projection 只做身份、拓扑、标签和可视列映射。UI 不直接写 `Game.state`、库存、operation、route、Shipment、project、research、ship 或 megastructure。

## Inspector 与命令边界

Context Inspector 顺序是：状态/首要 blocker → 实际行为与吞吐 → 输入/输出/库存/在途/需求 → 高频解决入口 →高级设置 →危险操作。双击或 Enter 使用 Projection 的 navigation target 打开原有列表/设施/库存/物流/需求控制页。

写操作只能经现有 `Game.*` 命令。目前网络 Inspector 的生产停止调用 `Game.stop_industry_operation`；其他对象打开既有详情页面。Disabled action 必须保留可见原因/tooltip，UI 不模拟成功结果。

## 布局、偏好与恢复

以下数据存放在 `user://core_gameplay_ui.cfg` 的 UI 配置，而不是玩法存档：

```text
industrial_network.workspace
  version
  positions[locationId][stableNodeId] = [x, y]
  viewports[locationId] = { zoom, scroll }
  layers = { MATERIAL, LOGISTICS, DEMAND, SERVICE }
  product_filter

display.reduced_motion
navigation.industry_view_mode
```

缺少位置时按 Domain column 与 stable ID 确定性排列；逻辑列会压缩为空间连续列。新增节点只取得新位置，不移动已保存节点。数值类型、范围或结构损坏时忽略该条记录并回退确定性布局。提供自动整理、适应全部、聚焦选择和定位瓶颈。

## Reduced Motion 与输入

Reduced Motion 是跨存档 UI preference。开启后关闭粒子和呼吸、相机移动近乎即时；所有状态仍由文字、形状、图标、填充和静态颜色完整表达。

输入合同：鼠标选择/拖动节点、滚轮缩放、GraphEdit 原生平移、中键或 `Space + Drag` 平移；Tab 可进入 GraphNode，Enter 打开实体；Escape 先清过滤/瓶颈/选择/Inspector，再走统一 Navigation Back。重建保持 stable control identity、画布位置和选择；隐藏网络不推进连续视觉时钟。

## 性能策略

- Simulation 快照由 Main 的 dirty/coalesced scheduler 低频请求，隐藏页不刷新。
- Projection 使用稳定签名和 ID；View 对节点做增删改 diff，相同节点不重建。
- EdgeLayer 缓存世界 Bézier 和屏幕路径，批量 `_draw()`，不为每个粒子创建 Node。
- zoom/pan 只更新屏幕路径；节点移动或拓扑变化才重建世界路径。
- 视口外边通过 bounds test 跳过昂贵绘制。
- 100 节点/200 边自动化合同记录首次构建耗时并验证第二次相同快照保留节点实例。

## 参考转化与原创边界

`UI-reference/` 的 Upload Labs 截图现为非规范历史材料，不再指导正式 UI 布局。工业网络与全局 Shell 的信息结构、工作区密度、上下文检查器和操作反馈改以 `D:\Projects\DSPONLINE` 的原则为主要参考；实现不复制其 React/CSS、字体、图片、图标、品牌、节点内容或代码，Helios 继续使用自己的工业对象、语义 token、原创 glyph、Context Inspector 和轨道工业尺度。

DSPONLINE 仅用于动态节奏与性能思路：真实流量驱动、拥堵降速、共享画布时钟、暂停域动画、低频警告、一次性恢复反馈、viewport culling、topology/runtime 分离和 Reduced Motion。没有复制 React、CSS、组件、资产、数据或品牌。

## 首阶段限制

- 当前连接不可编辑；网络是只读运行结构和命令入口。
- Service 图层的数据接口和过滤已存在，首批 Projection 主要在 Infrastructure 节点/Inspector 展示能源与散热，尚未为每项服务制造常驻边。
- 默认布局是确定性列布局，不是全局最短交叉优化；超大后期图依靠产品聚焦、瓶颈聚焦、折叠侧栏和手动整理。
- 线路标签在小缩放默认隐藏，以保证 1366×768 可读性。
