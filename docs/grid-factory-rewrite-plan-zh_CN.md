# 方格工厂玩法重构计划

> 生效分支：`feat/gridworks-dsponline-rework`
>
> 首个实现版本：`1.30.0-grid-factory-foundation` / Save Schema 36
>
> 决策日期：2026-09-01

## 1. 已确认的新方向

旧的“地点页面选择一个抽象活动，然后等待进度条完成”的采矿、生产和普通建设模式被推翻。新的核心玩法是：

```text
1 平方米方格组成行星可用面积
→ 固定矿体占据确定坐标
→ 玩家规划宏观设施 Footprint
→ 端口和线路形成资源、电力、货运网络
→ 设备按真实输入、输出、功率和吞吐运行
→ 生产出的资本品进入实体仓储
→ 建设订单从实体仓储取得材料并完成新设施
```

画布交互和空间反馈参考 Factorio；固定资源、端口、连接、状态灯和反压参考 Gridworks；实体、线路、配方、电网、建设队列、蓝图和结算阶段参考 DSPONLINE。Godot 代码、内容、美术和品牌仍在本项目内独立实现。

## 2. 尺度定义

- 一个 Tile 的逻辑面积固定为 1 平方米。
- 画布边界代表天体的全部可用面积，但不创建 `width × height` 常驻数组。
- 64×64 Tile 组成一个 Chunk。
- 未修改地表由 `seed + generator_version + chunk coordinate` 重建。
- 存档只保留固定矿体、已揭示区域、Tile 差量、玩家设施、线路和建设订单。
- 近景显示米制格线和精确占地；远景按 Chunk、区域、矿体和工业网络聚合。
- 玩家建造的是大型采掘场、冶炼区、仓储区、电站和运输走廊，不进入建筑内部逐台摆放机器。

## 3. 新权威状态

Schema 36 在 `SpaceGameState.factory_worlds` 中加入：

```text
Factory World
├── bounds / seed / chunk size
├── fixed deposits
├── placed entities
│   ├── extractor
│   ├── machine
│   ├── storage
│   ├── power
│   └── construction facility
├── links
│   ├── RESOURCE
│   ├── CARGO
│   └── POWER
├── construction orders
├── tile deltas / revealed chunks
└── production / consumption / transfer statistics
```

这一聚合由 `FactoryGridSimulation` 结算。UI 只能通过 `Game` 的事务命令创建世界、注册生成器矿体、提交建设、交付材料和建立连接。

## 4. 第一阶段已经落地

当前纵向切片已经具备：

- 行星级稀疏米制地址空间。
- 稳定 Chunk 和 Chunk 内坐标。
- 可确定性重建的基础地表属性。
- 固定、多格连续资源矿体。
- 宏观建筑 Footprint、边界和碰撞校验。
- 只有兼容采集设施能够覆盖固定矿体。
- RESOURCE、CARGO、POWER 三类连接。
- 普通货运输入端口单连接约束，避免绕过合流设施。
- 同优先级公平分配和高、中、低线路优先级。
- 独立电网与按 `Supply / Demand` 比例执行的欠压降速。
- 采矿缓存、配方输入输出缓存和实体仓储。
- 线路吞吐、满仓反压和空间恢复后的自动继续。
- 使用实体仓储物资资助建设订单。
- 建设能力、优先级、工时和完成领域事件。
- 生产、消费、转运统计，以及实体缓存/施工暂存分域的资产账本与物资守恒测试。
- Schema 35 → 36 显式迁移和方格世界存档往返。

首个验证链为：

```text
固定铁矿体
→ Surface Mining Field
→ iron_ore CARGO link
→ Macro Arc Smelter / grid_refine_iron
→ iron_ingot CARGO link
→ Bulk Storage Depot
→ 消耗 10 iron_ingot 建造第二座 Depot
```

## 5. Schema 36 硬切换边界

旧聚合工业不再与方格工厂并行。Schema 36 载入时会归档并清空旧普通工业运行态；舰船、科研、远征和跨地点物流仍保留自身领域模型，但不得继续调用旧工业结算：

| 系统 | 当前权威 | 迁移状态 |
| --- | --- | --- |
| 方格矿体、采矿、局部货运、局部电网 | `FactoryGridSimulation` | 新核心已建立 |
| 方格配方机器与实体仓储 | `FactoryGridSimulation` | 新核心已建立 |
| 方格普通建设 | `FactoryGridSimulation` | 新核心已建立 |
| 旧采矿活动与自动采集网络 | 无活跃权威 | Schema 36 归档并清空；命令永久拒绝 |
| 旧 Production Line / Facility 聚合生产 | 无活跃权威 | Schema 36 归档并清空；命令永久拒绝 |
| 旧普通 Construction Project | 无活跃权威 | Schema 36 归档并清空；方格建设取代 |
| 旧 Facility、地点 Industry Level、制造模块与抽象电力容量 | 无活跃权威 | 元数据归档并清空；必须由方格实体重新表达 |
| 地点间运输 | `LogisticsEngine` | 保留，之后接实体星港/仓储端点 |
| 舰船、科研、远征、战斗 | 现有领域模块 | 舰船仅保留战斗、探索和实际运输；逐步接入方格物资端点 |
| 巨构普通施工阶段 | 待重接 | 旧 Construction 已移除，必须改接方格建设或专用空间工程实体 |

`retired_aggregate_industry_archive` 只保存迁移取证，运行时不得读取它计算产量、进度、需求或解锁。新存档不再序列化 `mining_operations`、`mining_site_states`、`extraction_command`、`industrial_operations`、`construction_operations`、`extraction_network_states`、旧 `automation_rules`、`background_economy` 与制造模块库存。旧 Facility/地点 Industry 元数据也不能继续满足工业解锁或提供抽象产能；星港、科研、舰船等独立领域设施不在这次删除范围内。旧槽位自动化不是新方格自动化的兼容入口。同一批物资仍只能有一个库存权威；跨地点装卸必须通过显式 Port Transfer 事务改变所有权。

新游戏由 `factory_grid_rules.starter_world` 数据直接建立稀疏地球画布、固定铁矿区和初始实体仓库；初始工业物资从地点库存移动到实体仓库，不复制所有权。旧存档不会凭空猜测建筑坐标，必须通过后续迁移放置流程进入画布。

Schema 38 完成舰船职责硬切换：采矿/施工插件、舰船采集活动与旧矿舰内容不再进入 `ContentDatabase`，迁移负责剥离旧装配、把终极矿舰映射为物流方舟，并把旧工程舰映射为代达罗斯重型运输舰。战斗掉落和远征产品仍使用真实编队货舱。未来入侵战结束后由 `WreckSiteSystem` 创建有限残骸点，打捞/分析共用工作量并在耗尽后消失；它不是舰船工作槽。

## 6. 接下来的开发顺序

### P1：可玩的行星画布

- Godot `Node2D` 方格画布、相机平移/缩放和米制 Picking。
- Chunk 加载、卸载、脏标记和两级 LOD。
- 地表、固定矿体和宏观设施的批量渲染。
- Palette → Footprint 预览 → 碰撞/资源/科技校验 → 建设订单。
- 端口拖线、线路预览、取消和 Inspector。
- 实际流量驱动的货运动画与运行状态。

完成标准：玩家通过方格画布获得第一批铁矿和铁锭；旧 Mining/Industry/Construction 命令已经永久拒绝，不能作为临时捷径。

### P2：内容链迁移

- 把现有活动中的生产输入、输出和周期整理为 `factory_recipes`。
- 把旧设施、生产装置和方法整理为宏观建筑代际、兼容配方和模块。
- 每条核心链至少拥有真实矿体、采集设施、加工设施、仓储和建设用途。
- 建立资源地理、新手矿体闭包和确定性生成器。
- 采用“先按 abundance 选择资源，再按地理适配选择位置”。

完成标准：钢铁、电子、能源、建设件和基础科研耗材全部通过方格网络生产。

### P3：物流与蓝图

- 显式 Splitter、Merger、总线端口和过滤规则。
- 线路升级、并联、优先级、监控和拥堵解释。
- 批量连接原子校验，失败不部分扣料。
- 蓝图保存实体、线路、旋转、镜像、外部端口和资源锚点。
- 蓝图部署先创建不可变 Plan，再进入建设队列。
- 星港把实体仓储接入地点间 Logistics Engine。

完成标准：跨区域供给必须从物理仓储经过星港和在途运输抵达另一个方格世界。

### P4：旧源码与 UI 清场（运行态退役已完成）

- Schema 36 已将旧 `mining_operations`、`industrial_operations`、`construction_operations`、`extraction_network_states` 转为只读迁移证据并移出活跃存档。
- 旧 Mining/Industry/Construction 应用命令已经永久拒绝，主模拟不再推进或结算这些运行态。
- 旧工业公式和规划器投影已从核心查询链删除；继续清理旧页面、Action Registry 和未迁移测试夹具。
- 科研、舰船和巨构若需要工程施工，必须接方格建设或建立明确的专用空间工程实体，不能复用旧普通 Construction。
- 更新 Guidance、Golden Path、Planner 和所有 UI 状态注册表。
- 增加旧存档的可视化迁移向导，不凭空猜测设施坐标。

完成标准：正常新存档不能通过任何旧聚合命令生产普通资源或商品。

## 7. 模拟顺序

每个方格工厂步遵循稳定顺序：

```text
累计本步线路容量
→ 运输上一步已经存在的输出
→ 计算独立电网 Supply / Demand
→ 运行采集设施
→ 运行配方机器
→ 用本步剩余线路容量运输新输出
→ 推进已交付材料的建设订单
→ 发布结构化事件和只读快照
```

所有实体和线路按稳定 ID 处理；同一来源的同优先级线路使用轮转公平分配。UI 动画只读取 `last_flow`，不能自行推断或制造货物。

## 8. 必须维持的测试门禁

- 大世界创建不分配全图 Tile 数组。
- 同 seed、版本和坐标生成相同地表与矿体。
- 固定资源不能移动、复制或被普通建筑覆盖。
- 建筑 Footprint 不越界、不互相重叠。
- 端口方向、资源、物品和占用必须兼容。
- 电力不足按网络统一比例降速。
- 输入不足、无电、无资源、输出满和路线缺失具有结构化状态。
- 满仓不删除产物，释放空间后自动恢复。
- 分流结果不依赖 Dictionary/Array 遍历顺序。
- 工厂全域满足 `期初实物 + 生产 = 期末实物 + 消费 + 明确定义损失`；内部转运只改变持有者。
- 施工拨料仍属于 `FactoryWorld.ConstructionStaging`，只在设施完成时计入消费。
- 建设不即时生成设施，材料和工时均完成后才提交实体。
- 在线、离线、存档往返保持结果一致。
- Location Inventory 与方格实体仓储之间不存在隐式镜像。

## 9. 尚未解决的关键问题

- 行星画布实际宽高、可用面积和不可建设地表比例尚未定稿。
- 固定矿体目前采用可持续产能；是否引入 Factorio 式有限储量仍是独立经济决策。
- 本地线路当前以端点和容量结算，实际路径 Tile 与施工成本将在画布阶段加入。
- 方格世界与星港/地点间物流的所有权移交协议尚未实现。
- 旧存档不能自动推断历史抽象设施应该放在哪个坐标；旧运行态已归档且不会恢复，后续迁移向导只能显式创建新实体。
- 当前基础设施冷却语义仍需从旧地点容量模型翻译为实体网络或服务覆盖。

旧运行字段已经从 schema 36 的正常存档输出中删除，只保留一个不可执行的迁移档案。所有普通生产和建设必须进入 `FactoryGridSimulation`，不得增加任何旧聚合按钮回退路径。
