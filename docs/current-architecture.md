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
- 状态层：`src/core/game_state.gd` 保存地点库存、已安装设备、运输中资产、项目暂存、舰船、研究、勘测和终局状态。
- 查询层：`src/core/economy_planner.gd` 使用与模拟相同的内容和计算入口，提供经济快照、依赖展开与瓶颈链。
- 展示层：`src/ui/main.gd` 和组件只调用应用命令；所有核心流程必须能在 UI 中完成。

## 资产状态

```text
Inventory.Available
↔ Inventory.Reserved / ProjectStaging
↔ InTransit
↔ Installed / Assigned
→ Consumed / Defined Loss
```

生产只能通过 `Factory + Installed Production Device + Production Method` 发生。地点库存受 Storage Class 容量限制；输出满仓、输入不足、能源不足、散热不足和物流受限均由模拟给出明确状态。

## 扩展原则

- 复用正常 Construction Project 表达地点开发和终局工程阶段。
- 复用正常 Demand Registry 表达维护、建设、研发和造船需求。
- 地点差异来自环境条件、资源潜力、运输周期和维护品消耗，不使用地区职业或无条件百分比 Buff。
- 单恒星系边界是当前产品约束；不保留跨恒星运行入口。
- 性能优化使用内容依赖图缓存、状态修订号和事件驱动 UI 刷新，避免每帧全图递归。

