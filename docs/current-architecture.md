# 当前架构

更新时间：2026-08-27

## 运行边界

当前产品只模拟一个恒星系。`ContentDatabase` 是内容定义入口，`SpaceGameState` 是唯一可持久化状态，`SimulationEngine` 是生产、建设、研发、运输、维护、勘测与项目推进的规则权威。UI 和只读规划器只能查询这些规则或通过 `Game` 的事务命令改变状态，不允许直接改库存数字。

## 分层

```text
data/content.json + localization
                ↓
       ContentDatabase（校验、索引、依赖图）
                ↓
 Game（事务、玩家命令、存档生命周期）
                ↓
 SpaceGameState ← SimulationEngine → LogisticsEngine
                ↑          ↓
     EconomyPlanner / Diagnostics（只读）
                ↑
          Godot UI（命令与展示）
```

- 内容层：产品、生产方式、设施、生产装置、舰船、科研、地点、勘测、路线、目标和终局工程均由内容数据定义。
- 应用层：`src/application/game.gd` 对外提供带校验的事务命令，并负责存档加载、离线推进和事件转发。
- 领域层：`src/core/simulation_engine.gd` 统一计算配方吞吐、能源、散热、仓储、维护、建设、研发和任务边界。
- 状态层：`src/core/game_state.gd` 保存地点库存、已安装设备、运输中资产、项目暂存、舰船、命名舰船设计（画布节点与玩家连线）、研究、勘测和终局状态。
- 查询层：`src/core/economy_planner.gd` 缓存 DAG 依赖图并调用模拟的有效 BOM、工时与能耗公式，提供商品吞吐、舰船/月、研发阶段和巨构阶段规划以及瓶颈链。
- 展示层：`src/ui/main.gd` 和组件只调用应用命令；所有核心流程必须能在 UI 中完成。`Game.guidance_snapshot()` 提供页面、子区域、地点、聚焦实体、阻塞原因和获取链。

舰船装配遵循独立的编辑提交边界：`ShipAssemblyMapView` 只维护当前未保存草稿，Palette 拖拽只创建舰体/零件节点，GraphEdit 连接只表达玩家意图；船体节点根据内容定义的 `slot_layout` 形成不同规模的装配背板，并把能源核心作为中央必需插槽。装配线直接采用 DSPONLINE 画布的短引线/共享横轨/短接入正交路径与节点避让逻辑，未连接插槽为空心灰色，连接后才按类型填色。画布使用页面剩余高度并支持按全部节点边界动态适配全图，舰船 Palette 仅投影 `unlocked_ship_plans` 中当前可用的舰体方案。`Game.ship_design_validation/save_ship_design/enqueue_saved_ship_design` 负责领域校验、事务持久化和进入船厂。`SimulationEngine.shipyard_runtime_plan` 将已保存设计的真实模块清单用于 BOM 与完工舰船，不从 UI 草稿或模板默认连线推断结果。

## 资产状态

```text
Inventory.Available
↔ Inventory.Reserved / ProjectStaging
↔ InTransit
↔ Installed / Assigned
→ Consumed / Defined Loss
```

生产只能通过 `Factory + Installed Production Device + Production Method` 发生。地点库存受 Storage Class 容量限制；输出满仓、输入不足、能源不足、散热不足和物流受限均由模拟给出明确状态。

`SpaceGameState.asset_ledger_snapshot()` 按物品汇总 Available、Reserved、InTransit、ProjectStaging、InstalledAssigned、Consumed 与 Lost。物流事务同时记录质量、体积和路线占用；移动所有权不计为生产或消费。

## 扩展原则

- 复用正常 Construction Project 表达地点开发和终局工程阶段。
- 复用正常 Demand Registry 表达维护、建设、研发和造船需求。
- 地点差异来自环境条件、资源潜力、运输周期和维护品消耗，不使用地区职业或无条件百分比 Buff。
- 单恒星系边界是当前产品约束；不保留跨恒星运行入口。
- schema 35 以前的 `background_economy` 仅为迁移取证数据，运行入口永久返回空；内容校验拒绝所有旧后台产能效果。
- 性能优化使用内容依赖图缓存、状态修订号和事件驱动 UI 刷新，避免每帧全图递归。
