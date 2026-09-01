# 当前架构

更新时间：2026-09-01

## 运行边界

当前产品只模拟一个恒星系。schema 36 已开始把采矿、生产和建设从地点级按钮操作迁移到 Factorio 式方格工厂；schema 37 移除了按工作类型划分舰队的模型；schema 38 则彻底删除舰船采矿/施工插件和对应内容、命令与能力字段。舰船只加入通用编队，承担战斗、探索和真实运输。`ContentDatabase` 是内容定义入口，`SpaceGameState` 是唯一可持久化状态，`SimulationEngine` 与 `FactoryGridSimulation` 共同承担规则权威。UI 和只读规划器只能查询这些规则或通过 `Game` 的事务命令改变状态，不允许直接改库存数字。

## 分层

```text
data/content.json + localization
                ↓
       ContentDatabase（校验、索引、依赖图）
                ↓
 Game（事务、玩家命令、存档生命周期）
                ↓
 SpaceGameState ← SimulationEngine → LogisticsEngine
       ↑              ↕             WreckSiteSystem
 factory_worlds ← FactoryGridSimulation
       ↑              ↓
     EconomyPlanner / Diagnostics（只读）
                ↑
          Godot UI（命令与展示）
```

- 内容层：产品、方格规则、宏观建筑、工厂配方、生产方式、舰船、科研、地点、勘测、路线、目标和终局工程均由内容数据定义。
- 应用层：`src/application/game.gd` 对外提供带校验的事务命令，并负责存档加载、离线推进和事件转发。
- 领域层：`src/core/factory_grid_simulation.gd` 结算固定矿体、实体占地、端口、电网、货运、配方、反压和方格建设；`src/core/simulation_engine.gd` 协调舰船、科研、跨地点物流与维护，但不再推进地点级采矿、Production Line、Extraction Network 或普通 Construction。
- 状态层：`src/core/game_state.gd` 的 `factory_worlds` 保存方格世界、实体、线路、建设订单和实体缓存；地点库存、运输中资产、舰船、研究、勘测、有限残骸点和终局状态继续保留。各保管域不得同时拥有同一批物资。
- 查询层：`src/core/economy_planner.gd` 从 `factory_recipes`、方格建筑、实体缓存、固定 Deposit 与实际物流路线建立只读 DAG 和瓶颈链；舰船/月、研发阶段和巨构阶段只提供 BOM 目标，不再借用旧 Production Line 估算虚构产能。
- 展示层：`src/ui/main.gd` 和组件只调用应用命令；所有核心流程必须能在 UI 中完成。`Game.guidance_snapshot()` 提供页面、子区域、地点、聚焦实体、阻塞原因和获取链。

舰船装配遵循独立的编辑提交边界：`ShipAssemblyMapView` 只维护当前未保存草稿，Palette 拖拽只创建舰体/零件节点，GraphEdit 连接只表达玩家意图；船体节点根据内容定义的 `slot_layout` 形成不同规模的装配背板，并把能源核心作为中央必需插槽。装配线直接采用 DSPONLINE 画布的短引线/共享横轨/短接入正交路径与节点避让逻辑，未连接插槽为空心灰色，连接后才按类型填色。画布使用页面剩余高度并支持按全部节点边界动态适配全图，舰船 Palette 仅投影 `unlocked_ship_plans` 中当前可用的舰体方案。`Game.ship_design_validation/save_ship_design/enqueue_saved_ship_design` 负责领域校验、事务持久化和进入船厂。`SimulationEngine.shipyard_runtime_plan` 将已保存设计的真实模块清单用于 BOM 与完工舰船，不从 UI 草稿或模板默认连线推断结果。

## 资产状态

```text
Inventory.Available
↔ Inventory.Reserved / ProjectStaging
↔ InTransit
↔ Installed / Assigned
→ Consumed / Defined Loss

FactoryWorld.EntityBuffers
↔ FactoryWorld.ConstructionStaging
↔ (future explicit Port Transfer) ↔ InTransit
→ FactoryWorld.Consumed
```

普通生产只能通过 `Fixed Deposit → Extractor → Cargo Link → Machine + Recipe → Storage` 发生。线路有真实吞吐，电网欠压按比例降速，输出满仓逐级反压。旧 Factory/Production Method、舰船点选采矿、Extraction Network 和普通 Construction 已退出运行态，不存在兼容产出路径。

战斗掉落回收与远征产品继续进入编队的 `recovered` 货舱，随后通过容量受控的卸货事务进入地点仓库；它们不是采矿。未来入侵事件结束后可调用 `WreckSiteSystem.create_after_invasion()` 生成有限残骸点，`SALVAGE` 与 `ANALYSIS` 消耗同一份 `remaining_work`，归零后活动点立即消失。该接口不接受舰船或编队参数，当前也不提前结算奖励表，避免形成常驻“打捞职业”。

`SpaceGameState.asset_ledger_snapshot()` 按物品汇总 Available、Reserved、InTransit、ProjectStaging、InstalledAssigned、Consumed 与 Lost，并在独立的 `FactoryWorld` 域列出实体缓存、施工暂存、生产和消费。仓储向施工订单拨料只改变保管域；设施完成时才消费材料。物流事务同时记录质量、体积和路线占用，移动所有权不计为生产或消费。

## 扩展原则

- 普通地表建设只使用方格 Construction Order；地点开发和终局空间工程必须另接方格建设或专用空间工程实体，不能复用已退役的普通 Construction Project。
- 复用正常 Demand Registry 表达维护、建设、研发和造船需求。
- 地点差异来自环境条件、资源潜力、运输周期和维护品消耗，不使用地区职业或无条件百分比 Buff。
- 单恒星系边界是当前产品约束；不保留跨恒星运行入口。
- schema 35 以前的 `background_economy`、槽位 `automation_rules`、抽象 Facility/Industry Level、矿点状态、采掘指挥容量和聚合工业运行态仅为迁移取证数据；schema 36 起 `factory_worlds` 是普通工业唯一权威。旧 `mining_operations`、`mining_site_states`、`extraction_command`、`industrial_operations`、`construction_operations`、`extraction_network_states`、`automation_rules`、`background_economy` 与制造模块库存不再序列化、推进、查询或结算。
- schema 37 的 `fleet_formations` 是舰船编队唯一权威；编队不带工作类型。旧 `extraction_assets` / `expedition_fleet` 不再序列化，旧远征成员迁入默认特遣队。
- schema 38 删除采矿与施工支援插件、舰船采集活动和旧矿舰内容；迁移会剥离旧插件，把 `ultimate_miner` 映射为 `ultimate_transport`，并把旧 `mobile_constructor` 保留身份地转为 `heavy_lift_transport`。`wreck_sites` 只保存入侵战后有限残骸点，不是舰队工作槽。
- 性能优化使用内容依赖图缓存、状态修订号和事件驱动 UI 刷新，避免每帧全图递归。
