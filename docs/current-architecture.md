# 当前架构

> 更新：2026-09-10。本文描述当前运行权威；道路前的端口、实体仓储、现场施工与 Port Transfer 方案不再是架构要求。Factory 细则见[道路工业设计](./Planetary_Industry_Roads_Design_zh_CN.md)，范围标签见[内容同步状态](./Content_Synchronization_zh_CN.md)。

## 权威边界

```text
data/content.json + data/dsponline_industry.json + localization
                         ↓
                  ContentDatabase
                         ↓
      Game（事务、命令、存档生命周期、离线推进）
                         ↓
 SpaceGameState ← SimulationEngine → LogisticsEngine
       ↑                    ↑
 factory_worlds      Location inventory / research / fleets
       ↑
 FactoryGridSimulation + FactoryRoadNetwork + FactoryRoadTransport
       ↑
    Factory Workspace snapshots and command intents
```

- `ContentDatabase` 是内容定义入口；`SpaceGameState` 是唯一持久化状态。
- `Game` 是玩家命令唯一入口。UI 只能读取快照、发送 intent，不能直接变更 `Game.state`、库存或 Factory 实体。
- `FactoryGridSimulation` 结算每个 `factory_world` 的边界、地形、资源田、建筑占地、道路连通、电力、本地在途货物、缓存、配方和部署幽灵。
- `SimulationEngine` 推进 Factory、地点环境、研究、舰船、勘测、项目与跨地点物流；`LogisticsEngine` 专属跨地点航运。道路不会修改航线、ETA、推进剂或舰船资格。

## Factory 的资产与物流

```text
Location inventory（每个物品独立容量，唯一星球库存）
       ↕ 道路可达仓库的装卸/接入
机器输入缓存 ← 道路在途货物 → 机器输出缓存
       ↓
建筑成品 → 已部署实体 / 缺货幽灵
```

- 仓库实体不保存第二份经济库存；同地点不同道路分量的仓库仍接入同一 Location 库存。
- 机器缓存、道路在途货物、舰队货舱、星际 Shipment 与项目暂存各自是独立保管域。转移必须先扣除原保管域；同一批物资不能镜像。
- 普通建筑通过“成品建筑 → 部署”完成。`construction_orders` 仅表达缺货幽灵和部署等待，不能成为普通现场 BOM、工时或施工暂存的第二套经济。
- 已建道路同时是本地货运和电力拓扑。未连接道路的建筑没有电；玩家不再创建本地 CARGO/POWER link、端口过滤或手动仓库进出口。

## Factory 状态与快照

- `factory_worlds` 保存世界边界/seed、稀疏资源田、地形差量、实体、道路、道路在途任务、部署幽灵、统计与 `dsp_effects`。
- 资源田不是实体或道路端点。地形和资源均可由 seed、版本和稀疏描述重建；不建立整颗星球的 Tile 数组。
- Factory Workspace 读取版本化快照，包含道路、道路物流摘要、共享库存投影、建筑供电/道路状态、资源/地形视图和调色板。命令使用事务、命令 ID 幂等和拓扑版本校验。
- `FactoryRoadTransport` 只调度单一星球内道路任务；`LogisticsEngine` 只调度地点间 Shipment。二者通过 Location 库存接续，不互相复制状态。

## 其它领域

- **研究**：项目阶段、材料、设施条件和原型由 `SimulationEngine` 推进。矩阵实验室通过 Factory 事件增加研究工作积分，不另建科技树。
- **舰船**：装配画布维护未保存草稿，提交后由 `Game` 校验和持久化；船厂根据已保存 BOM 制造舰船。舰船用于战斗、探索和跨地点运输，不承担采矿、施工或常驻打捞。
- **勘测与环境**：地点状态按调查阶段推进；环境影响发电、需求、建设难度和维护投影。调查结果生成远端世界的地形和资源情报，不授予地球开局包。
- **DSP 项目**：燃料、蓄能、喷涂、接收站、矩阵、发射、出口、黑洞确认、空间站与时间效果都记录在现有世界/项目权威中；没有第二套 DSP 物流或账号系统。

## 已退役与不在当前范围

- 旧地点级 `mining_operations`、`industrial_operations`、`construction_operations`、Extraction Network、背景工业、舰船采矿/施工职责和普通 CARGO/POWER 玩家连线不参与当前运行。
- 当前产品只运行单一 `sol` 恒星系。完整戴森球壳、第二恒星系、跨恒星物流和本地铁路不是当前架构目标。
- 区域蓝图、地形改造、完整车辆表现与大工厂负载基准仍是后续工作；有限矿量待产品确认。

## UI 契约

生产 UI 使用 1920×1080 逻辑视口，3840×2160 为主要视觉验收。窗口只做一次统一缩放和居中留白；Factory、星系图、研究和舰船装配的内容相机彼此独立。
