# Gridworks 采集逻辑分析与方格行星画布适配方案

> 分析日期：2026-09-01
>
> Gridworks 源码：`/Volumes/T9/Developer/projects/Gridworks`
>
> Gridworks 基线：`d585a8c3a3e73d0cff93a0d773bc67facb6c478e`（`main`）
>
> 目标项目：CoreGameplayLab / Godot 4.6.x
>
> 文档性质：只读源码分析、领域映射和实施建议；本文没有改动玩法代码。

## 1. 结论

Gridworks 的采集逻辑可以用于本项目，但应该采用“规则移植 + 架构融合”，不能直接复制 JavaScript，也不应让 Gridworks 的平面逐格工厂模型取代本项目现有的文明级地点、舰船、建设、库存和跨地点物流模型。

推荐方案是：

```text
Factorio 式二维方格行星画布（1 格 = 1 平方米）
→ 提供地表类型、固定资源点、宏观采集设施和星球内连接的可交互表现
→ 将有效采集网络解析为本项目已有 Mining Site / Mining Operation / Extraction Network
→ 产出进入现有 Location Inventory
→ 跨地点运输继续由现有 Logistics Engine 负责
→ 建设、能源、散热、仓储、维护和离线推进继续由现有领域系统结算
```

也就是说，方格行星画布负责回答“这平方米是什么地表、资源在哪里、设施占多大面积、如何接入、为什么停机”；现有核心经济负责回答“实际产出多少、进入哪个地点库存、谁消耗、怎样运输、离线期间发生了什么”。

Gridworks 最值得采用的五项规则是：

1. 资源点是固定、不可移动的世界节点，采集器必须明确绑定资源点。
2. 资源种类、品位、设备能力、电力比例、线路吞吐和输出空间共同决定实际产量。
3. 满仓必须反压采集，释放空间后自动恢复，资源不能凭空丢失。
4. 地图生成必须“先按丰度选择资源，再按该资源的地理权重选择位置”。
5. 前台舰船采集成熟后，可以把资源点并入稳定但较低效的永久自动采集网络。

不建议采用的部分：

- Gridworks 的 Satisfactory 内容、里程碑和具体数值。
- 720×480 平面方格以及 DOM/Canvas 输入代码。
- 每 0.1 秒遍历所有节点和连线的模拟方式。
- 每个采集器各自维护一个孤立的 `100` 单位通用缓存。
- 用 Gridworks 的 8 小时、0.5 秒步长离线模拟替换本项目现有的事件边界模拟。
- 允许普通输入/输出端口无限扇入、扇出的宽松连线规则。

这里的“1 格 = 1 平方米”应被定义为逻辑坐标精度，而不是要求启动游戏时为整个星球逐格创建对象。整个可用面积使用有限世界边界表示，地形和资源按 Chunk 确定性生成，运行时只加载视野附近以及发生过玩家改动的区域。

## 2. 分析范围与验证结果

本次实际阅读了 Gridworks 的以下权威内容：

- `README.md`
- `docs/SOURCE_OF_TRUTH.md`
- `docs/superpowers/specs/2026-07-15-grid-idler-rebuild.md`
- `docs/superpowers/specs/2026-07-18-iteration-2-design.md`
- `docs/superpowers/specs/2026-07-29-the-world-design.md`
- `docs/superpowers/specs/2026-07-29-bigger-world-design.md`
- `docs/superpowers/specs/2026-07-29-know-your-factory-design.md`
- `docs/superpowers/specs/2026-07-27-offline-progress-design.md`
- `docs/superpowers/specs/2026-08-23-visual-language-design.md`
- `docs/superpowers/specs/2026-08-23-tile-io-layers-design.md`
- `src/sim.js`
- `src/game.js`
- `src/fx.js`
- `src/icons.js`
- `tests/test_sim.mjs`
- `tests/test_fx.mjs`

执行结果：

```text
node tests/test_sim.mjs  → all sim checks passed
node tests/test_fx.mjs   → all fx checks passed
```

同时检查了 CoreGameplayLab 当前与采集相关的内容定义、状态、应用命令、模拟、规划器和 UI，包括：

- `data/content.json`
- `src/core/content_database.gd`
- `src/core/game_state.gd`
- `src/core/location_state.gd`
- `src/core/simulation_engine.gd`
- `src/core/economy_planner.gd`
- `src/application/game.gd`
- `src/ui/main.gd`
- `tests/headless_test.gd`
- `docs/Design_Direction_zh_CN.md`
- `docs/core-game-loop.md`

## 3. Gridworks 的采集系统是什么

### 3.1 架构边界

Gridworks 将程序明确分成两层：

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 纯模拟 | `src/sim.js` | 内容索引、地图生成、节点/端口、连线校验、采集、加工、电力、传输、存档归一化、离线推进 |
| 表现与输入 | `src/game.js` | Canvas 绘制、相机、命中测试、拖拽放置、连线、检查器、状态灯和小地图 |

`src/fx.js` 只保存瞬时视觉效果，不改模拟状态；这条边界值得保留。对于本项目，对应关系应是：

```text
SimulationEngine / GameState / ContentDatabase
≠
Planet renderer / Hex picking / Flow animation
```

星球表现层不能直接增加库存、修改资源点品位或自行计算最终产量。

### 3.2 固定资源点

Gridworks 的矿藏、油、水和植物都被实现为固定 `deposit` 节点：

```js
{ id, key: "deposit", x, y, res, cat, purity, mult, fixed: true, buf, status }
```

关键语义：

- 资源点不可移动、不可删除。
- 矿物和油通常只有一个资源输出口。
- 水按品位提供 2/3/4 个输出口。
- 植物资源会在自身缓存中持续生成叶片和木材，不需要采矿机。
- 资源点本身不直接向普通生产线输出矿石；矿物资源端口只能连接兼容采集器。

这比“在任意位置摆一个采矿建筑就开始产矿”更好，因为采集能力与地理位置形成了可见、可解释的关系。

### 3.3 采集器绑定

Gridworks 采矿机有三个核心属性：

- `minerCat`：可采集类别，例如 `mineral`、`oil`、`water`。
- `rate`：基础采集速率。
- `draw`：电力需求。

采集器的端口是：

```text
resource input  ← 固定资源点
item/fluid out  → 运输线路
power input     ← 电网
```

资源线连接成功时，矿点的 `resource` 和 `purity multiplier` 会写入矿机运行态：

```text
miner.depositRes
miner.depositMult
```

删除资源线时，这两个字段清空，采集器进入 `no deposit`。

### 3.4 采集公式

Gridworks 的矿机每 tick 产量为：

```text
mined_per_tick
= base_rate_per_minute
 × purity_multiplier
 ÷ 60
 × dt
 × power_ratio
```

其中：

- 品位：`impure = 0.5`、`normal = 1.0`、`pure = 2.0`。
- `power_ratio = min(1, network_supply / network_demand)`。
- 没有资源点、没有电力或输出缓存已满时，产量为 0。
- 每种矿物在矿机中的缓存上限是 100。
- `made` 只累计真正放入缓存的数量，不累计被缓存上限截掉的理论产量。

因此 Gridworks 的实际采集不是简单的“矿机等级 × 时间”，而是：

```text
设备能力
× 矿点品位
× 电网供给比例
× 输出空间
```

线路吞吐随后再限制能够离开矿机的数量。

### 3.5 电力网络

Gridworks 使用并查集，根据电力连线求出多个独立电网：

```text
每个网络：Supply / Demand
每个耗电节点：ratio = min(1, Supply / Demand)
```

这产生三种采集表现：

- `ratio = 0`：`no power`，红灯。
- `0 < ratio < 0.95`：仍显示 `mining`，但状态灯为黄色，产量按比例降低。
- `ratio ≥ 0.95`：绿色正常运行。

重要之处不是并查集算法本身，而是“欠压不是随机停机，而是可解释的连续降速”。

### 3.6 输出、运输和反压

Gridworks 在生产节点更新之后进行第二阶段传输：

1. 根据端口解析资源类型。
2. 根据皮带或管道等级获得每秒吞吐。
3. 计算源缓存、目标空间和线路本 tick 容量。
4. 取三者最小值。
5. 从源扣除并加入目标。
6. 在 `wire.flow` 记录实际流率，供动画和 UI 使用。

公式是：

```text
transfer = min(
  line_rate × dt,
  source_available,
  destination_free_space
)
```

目标满仓时不会吞掉产物。上游缓存最终装满，采集器进入 `output full`；空间释放后，下一 tick 自动恢复。

这是应该移植到方格行星画布的核心状态机。

### 3.7 分流、合流和运输中继

Gridworks 将物流节点视为带缓存的 1 入/多出、多入/1 出或 1 入/1 出中继。

分流器对 tick 开始时的缓存做快照，并按已连接输出数量执行比例公平分配，避免第一条连线先消耗完缓存导致后续线路饥饿。

对于方格行星画布，等价规则可以用于：

- 一个矿区向多个本地仓库分配产出。
- 多个矿区汇入一个星港或质量投射器。
- 相邻地块中的管线、轨道或运输节点。

但不能直接复制其普通端口占用规则，见第 9 节风险。

### 3.8 前台采集到自动网络

Gridworks 本身是“采矿机一直运行”的自动化游戏。与本项目更接近的自动化升级逻辑已经存在于 CoreGameplayLab：

```text
舰船在永久采掘点进行前台采集
→ 累积 Site Mastery
→ 满足科技、永久设施和采集网络条件
→ 将 Site 集成进 Extraction Network
→ 释放舰船
→ 地点获得稳定后台产出
```

因此不需要新造一套自动采集成熟度系统；只需要让方格行星画布把这个过程表现出来。

## 4. Gridworks 的地图生成逻辑

### 4.1 确定性种子

Gridworks 使用 `mulberry32(seed)`。同一 seed 生成相同矿点种类、位置和品位，测试也明确验证：

- 相同 seed 的地图完全相同。
- 不同 seed 的地图不同。

本项目已有 `DomainRng` 与版本化 RNG 状态，应保留当前 RNG 权威，不需要照搬 `mulberry32`；但星球拓扑和资源分布必须同样满足“seed + topology version → 稳定结果”。

### 4.2 资源分层

Gridworks 按进度为资源定义 0–4 阶，并让不同资源偏好距离 HUB 不同的范围：

```text
tier ideal = tier / 4
tier factor = max(0, 1 - abs(distance - ideal) / band_width)
```

高阶资源另有最小距离硬门槛，避免铀等晚期资源出生在 HUB 旁边。

这一思路可以直接迁移到方格画布，但距离函数必须由玩法语义明确指定：

- 设施铺设与路径长度使用四向或八向方格图距离。
- 资源分层可以使用相对 HUB 的归一化欧氏距离，避免产生明显的方形同心带。
- 海拔、纬度、生态区和危险度可以成为独立位置权重。
- 画布边缘是星球“可用面积”的边界；除非设计明确需要环绕地图，否则不要默认把左右或上下边缘连接起来。

### 4.3 必须保留的纠错：资源优先，位置其次

Gridworks 曾经先随机位置，再根据该位置的距离权重选择资源。这个做法导致资源总量受到各阶层地理面积影响：低阶资源偏好的中心圆面积小，高阶资源偏好的外围面积大，最后低权重的铝土矿反而比高权重铁矿更多。

修正后的顺序是：

```text
1. 只根据内容定义中的 abundance/weight 选择资源种类。
2. 为已经选中的资源生成多个候选位置。
3. 根据该资源对位置的偏好进行加权蓄水池选择。
4. 丰度决定“有多少”，地理权重只决定“在哪里”。
```

这是本次分析中最值得直接采用的地图生成原则。

方格行星画布的建议流程：

```text
定义稳定的世界边界、Chunk 网格和生成器版本
→ 先放置必需的新手资源组合
→ 按内容 abundance 选资源类型
→ 从符合条件的 Chunk 与 Tile 中抽取候选集
→ 用地表类型、生态适配度、HUB 距离、危险度和矿体间距为候选打分
→ 加权选出矿体位置、形状和覆盖地块
→ 为每个含矿地块固定 deposit_id / resource / initial reserve / grade
→ 载入时按 seed 重建基础数据，只读取已勘测、已开采和玩家修改的差量
```

### 4.4 新手资源保证

Gridworks 先放置固定的新手组合，再使用剩余预算散布一般矿点：

- 铁矿 ×2
- 铜矿 ×1
- 石灰石 ×1
- 植物 ×2
- 水 ×1

这些保证点计入总资源预算，而不是额外增加地图总资源量。

本项目应使用内容依赖图计算“新存档完成第一条工业链的最小资源闭包”，不要硬编码 Gridworks 的 Satisfactory 组合。当前 CoreGameplayLab 的新手闭环至少需要保证能够形成：

```text
mixed_raw_ore
→ iron_ore / copper_ore
→ iron_ingot / copper_ingot
→ structural_frame
```

如果以后星球直接分布独立矿种，新手保证也必须从当前内容依赖图和 Golden Path 推导，而不是凭美术或直觉指定。

## 5. CoreGameplayLab 当前已经有什么

本项目并不是从零开始做采集。现有实现已经覆盖了 Gridworks 规则的大部分高级版本。

### 5.1 内容层

`data/content.json` 已存在：

- `mining_locations`：资源类型、品位、可持续潜力、危险和所属地点。
- `resource_regions`：资源地理与可产资源。
- `mining_sites`：永久采掘点、熟练周期和解锁要求。
- `mining_hazards`：危险对应能力与可预测 uptime。
- `extraction_methods`：移动采集、固定开挖、深层断裂、气体舀取。
- `extraction_networks`：成熟采掘点并入的自动网络。
- `activities[domain=mining]`：舰船前台采集活动及确定性产出。

### 5.2 勘测与信息揭示

现有地点遵循：

```text
UNKNOWN
→ DETECTED
→ SURVEYED
→ DEEP_SURVEYED
```

不同勘测层级逐步公开资源类别、潜力区间、品位范围、确切品位、高级潜力和副产物。方格行星画布应投影这套信息，而不是一开始把全部含矿格明牌展示。

建议表现：

| 勘测状态 | 星球地块表现 |
| --- | --- |
| UNKNOWN | 只显示生态色块，不显示资源图标 |
| DETECTED | 显示模糊资源类别或扫描轮廓 |
| SURVEYED | 显示资源类型、品位区间和可用采集方式 |
| DEEP_SURVEYED | 显示精确品位、潜力、危险和高级方法收益 |

### 5.3 舰船采集公式

当前舰船采集周期已经综合：

```text
installed_extraction = min(ship_mining_power, site_extraction_potential)

cycle_duration = extraction_cost
  / (installed_extraction
     × site_grade
     × extraction_method_efficiency
     × hazard_uptime
     × simulation_profile_multiplier)
```

这比 Gridworks 的 `base rate × purity × power ratio` 更适合当前产品，因为它还包含：

- 舰船的真实装配与采矿模块。
- 维护覆盖率。
- 资源点可持续潜力上限。
- 可预测的环境危险 uptime。
- 不同采集方法效率。

因此应该保留当前公式，将 Gridworks 的电力、线路和缓存限制作为新的乘数或硬瓶颈接入，而不是用 Gridworks 公式覆盖它。

### 5.4 永久采掘点建设

`queue_site_development()` 已经通过普通 Construction Project 建设永久采掘点，并消耗：

- 建设能力。
- 工业机床。
- 重型结构段。
- 电子设备。
- 受地点建设难度影响的工期。

方格画布中的“建设采矿设施”必须调用该命令或后续等价领域命令，不能点击地块后立刻免费生成矿机。

### 5.5 地点库存与满仓反压

采集产出进入资源所在地的 `Location Inventory`。当前模拟已经检查 Storage Class 容量，出现 `STORAGE_FULL` 时阻塞采集，并在空间恢复后自动继续。

这与 Gridworks 的缓存反压完全兼容，而且当前实现更严格：库存有地点所有权、货物类别、预留、在途状态和资产守恒审计。

### 5.6 自动采集网络

当前 `Extraction Network` 已支持：

- 绑定多个成熟 Site。
- 周期性产生地点资源。
- 用小数结转避免低速产量永久舍入为零。
- 满仓进入 `BLOCKED_OUTPUT`。
- 空间恢复后自动继续。
- 前台生产在同一结算边界优先占用共享仓储空间。
- 在线与离线共用事件边界模拟。

这部分不应该退回 Gridworks 的普通 10 Hz tick。

## 6. 对照与复用判断

| Gridworks 规则 | 当前项目对应 | 结论 |
| --- | --- | --- |
| 固定 Deposit 节点 | `mining_sites` + `mining_site_states` | 直接采用语义，在固定方格坐标上显示资源矿体 |
| purity 0.5/1/2 | `density`、`grade_range`、深度勘测 `grade` | 使用现有连续品位，不退化为三档 |
| Miner Category | 舰船模块 capability + Activity requirements | 使用现有能力系统 |
| Miner Base Rate | `mining_power` | 使用现有舰船装配计算 |
| Deposit output port | Site 到 Extractor 的资源绑定 | 适配为矿体与宏观采集设施的连接 |
| Belt/Pipe rate | 本地处理/装卸/路线吞吐 | 采用思想，不直接复制皮带 Mk 数值 |
| Power ratio | 地点能源容量、舰船 power budget | 需要接入采掘设施运行态 |
| Output buffer | Location Storage | 以地点库存为权威，不新增平行库存真相 |
| Output full | `STORAGE_FULL` / `BLOCKED_OUTPUT` | 已具备，保留 |
| Status light | 当前 Blocker / Gameplay State | 直接映射为地块边框与图标状态 |
| Site mastery | `mastery_cycles` / `mastery_level` | 已具备，保留 |
| Automated mining | `extraction_network_states` | 已具备，保留 |
| Offline tick | 事件边界 `advance()` | 不采用 Gridworks 粗步长 |
| Seeded mapgen | `DomainRng` + 未来 planet topology seed | 采用确定性原则，使用现有 RNG 体系 |
| Distance-tier resources | 当前进度地点 + 方格画布距离权重 | 可采用，但要由内容和依赖图驱动 |
| Gridworks Canvas | Godot 2D 分块方格画布 | 高度相符，但必须增加 Chunk、LOD 和宏观建造层 |

结论可以概括为：

```text
领域语义复用价值：高
地图生成原则复用价值：高
状态表现复用价值：高
源代码直接复用价值：低
现有 CoreGameplayLab 采集核心被替换的必要性：无
```

## 7. 推荐的融合架构

### 7.1 三层结构

```text
Planet Grid Canvas
  - 2D square tiles, 1 tile = 1 m²
  - chunk streaming / LOD / overview map
  - hover / selection / camera
  - terrain color / resource icon / facility footprint / flow animation
  - 不拥有库存和最终产量

Planet Extraction Projection
  - tile coordinate / deposit_id ↔ mining_site_id
  - extractor / local link / hub 的可视投影
  - 将玩家意图翻译成应用命令
  - 将 Simulation snapshot 翻译成地块状态

Existing Core Domain
  - ContentDatabase
  - SpaceGameState
  - SimulationEngine
  - LogisticsEngine
  - Construction Project
  - Location Inventory
```

### 7.2 权威数据流

```text
玩家选择资源地块
→ Planet UI 发出“开发 Site / 绑定采集器 / 建立本地连接”意图
→ Game 应用层开启事务
→ SimulationEngine 校验勘测、能力、建设、能源、散热、仓储和物流
→ 状态写入 mining_site_states / mining_operations / extraction_network_states
→ 模拟在事件边界结算
→ 产出写入对应 Location Inventory
→ UI 读取快照，播放采集器和流动动画
```

严禁：

```text
地块动画播放一次
→ UI 直接 state.add_item()
```

### 7.3 建议新增的行星画布数据

第一版可以增加独立的地理与建造结构，但不要复制现有地点库存和最终产量状态：

```gdscript
planet_surface_states[location_id] = {
    "schema_version": 1,
    "generator_version": 1,
    "seed": 12345,
    "tile_size_m": 1,
    "bounds_m": {
        "origin": Vector2i(0, 0),
        "size": Vector2i(width_m, height_m)
    },
    "chunk_size_tiles": 64,
    "hub_tile": Vector2i(x, y),
    "site_deposits": {
        "site_id": "deposit_id"
    },
    "revealed_chunks": {
        "chunk_x:chunk_y": survey_level
    },
    "tile_deltas": {
        "x:y": {
            "remaining_resource": optional_amount,
            "terrain_override": optional_terrain_id
        }
    },
    "structures": {
        "structure_id": {
            "origin_tile": Vector2i(x, y),
            "footprint_id": "...",
            "kind": "EXTRACTOR|RELAY|DEPOT|POWER",
            "site_id": "..."
        }
    },
    "links": {
        "link_id": {
            "kind": "RESOURCE|CARGO|POWER",
            "path_tiles": []
        }
    }
}
```

其中：

- `site_id` 仍是采集领域身份。
- `Vector2i(x, y)` 是 1 米方格的稳定逻辑地址。
- 每个基础 Tile 由 seed、生成器版本和坐标确定性得到 `terrain_type`、生态、海拔带、`deposit_id`、资源类型、品位、潜力密度以及可选的初始储量。
- 同一个连续矿体覆盖多个 Tile，并共享一个不可移动的 `deposit_id`；如果启用有限矿藏，单格再保存自己的初始储量与开采差量。
- 品位、潜力、开发方式、熟练度和自动化归属仍由现有 `mining_site_states` 与内容定义拥有。
- 不保存可由 seed 和 generator version 重建的未修改基础地块。
- 只保存勘测揭示、资源耗减、地形改造、设施和线路等不可重建差量。
- 玩家放置的结构和线路必须保存，因为它们是玩家意图，不能载入后重新随机。

### 7.4 “1 平方米 × 整个星球”的实现边界

`1 格 = 1 平方米`适合成为最小坐标和占地精度，但不适合成为全量常驻对象。假设可用画布是 20,000 km × 20,000 km，直接展开会得到 `4 × 10^14` 个格子；即使每格只占 1 byte，也需要约 400 TB。

必须采用以下结构：

- 世界边界以 64 位整数米坐标表示，不创建 `width × height` 数组。
- 推荐以 64×64 Tile 为一个 Chunk；生成、勘测、寻路、渲染和存档都以 Chunk 为基本分页单位。
- 基础地表和初始资源由 `seed + generator_version + chunk_coordinate` 确定性生成。
- 只实例化相机附近、正在模拟以及有玩家改动的 Chunk。
- 远景按 Chunk 或更高层 Macro Tile 聚合显示地形、资源密度、设施和告警。
- 近景才显示 1 米格线、单格资源属性和设施精确占地。
- 渲染使用 Chunk 纹理、批处理网格或等价批量方案，不能给每个 Tile 创建一个 Godot Node/Control。

因此，整个星球可用面积是统一、有限、可寻址的画布，但内存和存档始终是稀疏的。

### 7.5 宏观建造语义

画面可以像 Factorio 一样建立在方格和固定矿体上，但操作尺度不应变成逐格摆放每一条传送带：

- 单个采掘场、仓储区、电站或工业区使用 Blueprint Footprint，一次占用成百上千个 1 平方米 Tile。
- 玩家放置的是设施、功能区和运输走廊；系统根据范围生成详细占地或内部布局。
- 采掘设施必须覆盖或邻接兼容矿体，覆盖的含矿格共同决定可接触储量和可持续产能。
- 铁路、管道、电网和货运通道可以在方格上寻路，但领域层以端点、长度、容量和状态聚合结算。
- 远景操作使用框选、刷子、蓝图和区域规划，避免要求玩家点击数千个 1 米格。

方格是空间真相和视觉语言；宏观设施才是主要玩法单位。

### 7.6 固定矿体不等于有限矿藏

Gridworks 的 Deposit 位置固定但不会耗尽；当前 CoreGameplayLab 的 `sustainable_potential` 也主要表达持续产能。Factorio 则通常为每个含矿格保存有限数量。

第一版应保留当前经济语义：

- 方格固定保存 `deposit_id`、资源类型、品位和潜力密度。
- 采集受 Site Sustainable Potential、设施能力、能源、散热、线路和仓储限制。
- 不因为采用 Factorio 式画布就自动引入矿藏耗尽。

如果以后明确需要有限储量，再增加：

```text
initial_reserve_per_tile
remaining_reserve_per_tile
deposit_total_remaining
depleted state
资源守恒与枯竭后的设施处理
```

这会改变扩张节奏、物流需求、离线模拟和存档体积，应该作为单独的经济设计决策实施。

## 8. 推荐的采集状态机

### 8.1 资源地块

```text
UNKNOWN
→ DETECTED
→ SURVEYED
→ DEVELOPABLE
→ DEVELOPING
→ DEVELOPED
→ SHIP_OPERATED
→ NETWORK_INTEGRATED
```

可叠加运行状态：

```text
HEALTHY
POWER_LIMITED
COOLING_LIMITED
LOGISTICS_LIMITED
STORAGE_FULL
MAINTENANCE_LIMITED
NO_EXTRACTOR
NO_ROUTE
```

不要把“生命周期状态”和“阻塞原因”压进同一个字符串，否则 UI 很难同时表达“已开发但因满仓停机”。

### 8.2 产能公式

建议继续以当前公式为基础，新增星球内设施约束：

```text
installed_capacity = min(
  ship_or_extractor_power,
  site_sustainable_potential
)

theoretical_rate = installed_capacity
  × grade
  × extraction_method_efficiency
  × hazard_uptime

actual_rate = min(
  theoretical_rate × power_coverage × cooling_coverage × maintenance_coverage,
  local_link_capacity,
  local_handling_capacity,
  storage_acceptance_rate
)
```

如果采用离散 Cycle，则把 `actual_rate` 转换为下一次边界时间，继续使用当前事件边界模拟，不需要每帧或每 0.1 秒逐格结算。

### 8.3 本地连接类型

第一版只建议实现三类：

| 类型 | 起点 | 终点 | 作用 |
| --- | --- | --- | --- |
| RESOURCE | 固定矿体/含矿格 | 采集设施 | 证明设施覆盖或绑定了正确矿体 |
| CARGO | 采集设施/中继 | 本地仓库或星港 | 限制进入地点库存的吞吐 |
| POWER | 电源/电网入口 | 采集设施 | 提供运行覆盖率 |

暂时不要把冶炼、制造、科研和造船全部改成逐个 1 米格摆机器。当前产品方向是文明级生产网络；方格画布应提供宏观设施占地、资源地理和本地接入，而不是要求玩家手工复刻工厂内部的每台设备。

## 9. 已发现的风险与不能照搬之处

### 9.1 Gridworks 普通端口占用规则过宽

`canConnect()` 只对 `resource` 端口限制“一口一线”；普通 item/fluid 输入输出只禁止完全重复的同一对端点。

这意味着一个普通输出口可以直接连多个目标，一个普通输入口也可能接多个来源，从而绕过 Splitter/Merger 的设计意图。移植时必须明确端口容量：

- 单连接端口：最多一条有效连接。
- 总线端口：允许多连接，但有共享吞吐上限。
- 分流/合流设施：负责显式扇出/扇入和优先级。

### 9.2 Gridworks 的 tick 传输具有顺序敏感风险

Gridworks 对物流节点做了缓存快照来保证分流公平，但普通源节点的多条输出仍按 `state.wires` 顺序结算。大规模星球网络不应依赖数组顺序决定谁先拿到物资。

推荐使用：

```text
先计算所有请求
→ 按端口/总线容量分配
→ 再统一提交事务
```

### 9.3 Gridworks 的通用缓存不适合本项目

Gridworks 矿机和机器使用每资源 100 的固定缓存，Storage 使用总容量 2400。这适合小型网页原型，但本项目已有四类 Storage Class、预留、在途和地点所有权。

方格设施只需要保存必要的局部过程量或可视进度，不能成为第二套地点库存。

### 9.4 当前项目的 `cooling_demand` 尚未完整进入采掘运行校验

`extraction_methods` 定义了 `cooling_demand`，Site Development 完工也会设置相应散热容量；但当前 `extraction_site_infrastructure_status()` 只检查：

- power
- BULK storage
- local logistics throughput
- developed

没有检查 cooling。方格采集实施前应修正该领域缺口，并增加对应 Blocker 和测试。

### 9.5 当前 `efficiency_ratio` 是未被运行时消费的配置

`extraction_networks` 的 `efficiency_ratio` 会被内容验证和测试确认存在，但当前网络产量公式没有使用该字段；网络之所以看起来低效，是由 `quantity_per_site` 和 `cycle_time_ms` 的具体数值间接造成。

在新系统中应二选一：

1. 正式把 `efficiency_ratio` 接入网络理论产率；或
2. 删除该字段，并明确自动网络效率完全由周期和单周期产量定义。

不能继续保留“配置宣称有含义、运行时实际不读取”的状态。

### 9.6 产品尺度约束

`docs/Design_Direction_zh_CN.md` 明确反对把整个工业系统变成逐格摆机器，并要求地点容量和生产方式维持文明级聚合。

因此本方案默认：

```text
1 米格：地表属性、资源分布、精确占地、连接路径
宏观设施：采掘场、仓储区、电站、工业区和运输走廊
聚合：冶炼、制造、建设能力、仓储类别、跨地点物流、科研、造船
```

这与“Factorio 式画布、宏观建造”可以兼容：借用 Factorio 的空间连续性、固定资源和占地反馈，但一次操作的是大型设施或区域蓝图，而不是内部每台机器。如果以后改成逐格摆放整个工业链，那才是核心产品尺度变更，需要先修订正式设计方向、存档结构、性能预算和经济平衡。

### 9.7 星球并不等于所有 Location

项目术语表明确指出 Location 还包括轨道、基地、小行星带和拉格朗日点。方格行星画布是自然天体可用表面的抽象投影，不应该强行用于所有 Location。

建议为视觉载体增加类型：

```text
PLANET_SURFACE_GRID
ORBITAL_ZONE
ASTEROID_FIELD
LAGRANGE_SITE
ARTIFICIAL_HABITAT
```

只有具有可开发表面的天体使用 `PLANET_SURFACE_GRID`；其他地点继续使用适合自己的节点图或场景。方格画布表达的是可用面积与相对位置，不要求在视觉或拓扑上还原球面。

## 10. 分阶段实施建议

### P0：无存档变更的视觉验证

目标：证明 1 米逻辑坐标、分块渲染、固定资源投影和现有领域命令能够连接。

- 定义一个有限的行星可用面积边界，但不全量创建 Tile。
- 实现 64×64 Tile 的 Chunk 生成、加载和卸载。
- 为每格使用稳定 `Vector2i` 米坐标。
- 只把现有 Site 投影为少量固定资源矿体。
- 支持平移、缩放、悬停、框选和远近两级 LOD。
- 地块检查器显示当前 Site 的勘测、品位、潜力、方法和阻塞。
- “开始采集”“开发 Site”仍调用现有 Game API。
- 不保存可由 seed 重建的普通地表，不新增本地线路。

完成标准：关闭星球界面后，所有产量、库存和阻塞与旧 UI 完全一致。

### P1：Gridworks 式固定矿点与采集器绑定

- 增加资源格到采集设施的 `RESOURCE` 连接。
- 增加采集设施到本地仓库/星港的 `CARGO` 连接。
- 增加最小 `POWER` 接入。
- 明确端口单连接/总线规则。
- 连线仅改变采集网络配置，不直接改库存。
- 无有效链路时给出结构化 `NO_EXTRACTOR` / `NO_ROUTE` Blocker。

### P2：确定性星球资源生成

- 内容定义资源 abundance、生态适配、进度带和最低距离。
- 采用“资源优先、位置其次”。
- 新手保证资源计入总预算。
- 明确使用方格图距离或归一化二维距离，并测试边界行为。
- 保存 generator version、seed、世界边界、玩家差量和 Site 映射。
- 增加存档 schema 迁移。

### P3：吞吐、能源、散热与反压

- 将本地连接吞吐并入采集有效产率。
- 将 `cooling_demand` 正式纳入 Site 运行校验。
- 决定并落实 `efficiency_ratio` 语义。
- 使用统一请求—分配—提交事务，避免线路顺序影响。
- 保持 Location Inventory 和 Logistics Engine 为唯一库存/运输权威。

### P4：自动网络与表现

- Site Mastery 达标后允许集成自动网络。
- 集成时释放前台舰船，并把地块设施状态改为网络托管。
- 流动动画读取实际吞吐，而不是只要连线存在就播放。
- 状态变化播放一次克制脉冲，稳定运行不持续闪烁。
- 状态颜色与现有 UI-reference 的深蓝、青色、琥珀和少量紫色统一。

## 11. 必须增加的测试

### 11.1 方格、Chunk 与世界边界

- 每个合法米坐标唯一映射到一个 Chunk 和 Chunk 内坐标。
- Chunk 边界两侧的地表、矿体和连接连续，没有裂缝或重复生成。
- 世界边界外不能建造、勘测或寻路。
- 相同 seed、generator version 和坐标生成完全相同的基础 Tile。
- 加载再卸载未修改 Chunk 不产生存档差量。
- 打开行星画布不会创建整个世界的 Tile 数组或节点。
- 大范围平移时 Chunk 正确回收，内存占用受视野预算约束。

### 11.2 资源生成

- 同 seed 完全确定，不同 seed 有差异。
- 资源总丰度只由 abundance 决定，不受偏好区域面积改变。
- 地理权重只改变位置分布。
- 矿体生成后坐标和 `deposit_id` 固定，加载、缩放和 Chunk 回收不会移动资源。
- 连续矿体跨 Chunk 时仍保持同一身份，单格品位和潜力密度可重复恢复。
- 如果启用有限储量，单格初始储量、耗减差量和矿体总剩余量必须守恒。
- 高阶资源满足硬距离/勘测门槛。
- 新手资源闭包在所有测试 seed 中可用。
- 新手保证点计入总资源预算。

### 11.3 连接

- 类别不兼容的资源点与采集器不能连接。
- 单连接端口不能重复占用。
- 删除资源连接后采集器立即失去 Site 绑定。
- 路径必须由相邻地块组成。
- 删除设施会事务性删除悬空线路。
- 分流与合流不受数组遍历顺序影响。

### 11.4 产量与守恒

- 无采集设备、无电、无散热、无路线、满仓时产量为 0。
- 欠压/欠散热按明确比例降速。
- 采集器理论产量受 Site Sustainable Potential 封顶。
- 线路吞吐和地点装卸吞吐正确限制实际产量。
- 满仓不丢资源，空间释放后自动恢复。
- `生产量 = 库存增量 + 已运输 + 已消费 + 明确定义损失`。
- 自动网络和前台采集不会重复计算同一个 Site。

### 11.5 在线、离线与存档

- 同一时间跨度在线和离线结果一致。
- 离线期间发生满仓时，不继续虚增产量。
- 旧存档迁移后 Site、舰船、库存和 Network 归属不丢失。
- generator version 变化时有显式迁移或旧生成器保留策略。
- 星球表现数据不能成为第二个库存权威。

### 11.6 UI、LOD 与二维交互

- 在任意相机缩放和平移下，鼠标都能解析到正确的 `Vector2i` Tile。
- UI Scale 不改变世界米制坐标、设施占地或 Picking 结果。
- 悬停、选择、框选、拖拽平移和滚轮缩放互不抢输入。
- 远景隐藏格线和单格图标，但保留矿体、宏观设施、物流流向和告警。
- LOD 切换前后资源位置、设施轮廓和选择状态不跳动。
- 大型设施使用 Footprint 批量预览、碰撞检查和放置，不产生逐格操作负担。
- 流动动画速度来自实际吞吐率。

## 12. 推荐的第一批开发边界

为了最低风险验证玩法，第一批只做：

1. 一个有明确米制边界的二维行星方格画布，逻辑精度为 1 平方米。
2. 64×64 Tile Chunk 流送与近景格线、远景聚合两级 LOD。
3. 现有 Site 到固定资源矿体及含矿格的稳定映射。
4. 一种带大型 Footprint 的采集设施、一种本地仓库/星港入口。
5. `RESOURCE`、`CARGO`、`POWER` 三类宏观连接。
6. 勘测分层、悬停、框选、设施预览和检查器。
7. 通过现有 `start_extraction_operation()` 与 `queue_site_development()` 执行真实命令。
8. 产出仍进入现有 Location Inventory。
9. 满仓、电力不足、散热不足、无路线四类可视 Blocker。
10. 不引入逐台机器的星球内冶炼和制造，不修改跨地点 Logistics Engine。

这批完成后再根据实际可玩性决定是否让玩家手工铺设更复杂的本地网络。

## 13. 最终判断

“采用 Gridworks 的采集逻辑”是可行的，而且与当前系统并不冲突。实际上 CoreGameplayLab 已经拥有 Gridworks 采集逻辑的高级聚合版本；缺少的是把这些规则投射成一个有地理关系、可连接、能看见吞吐和阻塞的星球表面。

正确的开发目标不是重写采集模拟，而是：

```text
用 Gridworks 的固定矿点、端口、连接、吞吐和状态反馈
补齐 Factorio 式方格行星画布的局部交互层；

用 CoreGameplayLab 已有的勘测、舰船、建设、地点库存、
可持续潜力、维护、物流和事件边界模拟
继续承担最终领域结算。
```

如果按此边界开发，1 平方米方格能够提供清晰的空间和占地真相，宏观设施又能保持文明级操作尺度；Gridworks 则能显著提高采集玩法的可见性和操作感，同时不会破坏项目现有经济真相与存档兼容。

## 14. 源码索引

### Gridworks

- 架构与运行方式：`../../Gridworks/README.md`
- 数据权威政策：`../../Gridworks/docs/SOURCE_OF_TRUTH.md`
- 地图生成：`../../Gridworks/src/sim.js:210-360`
- 固定 Deposit 与新游戏：`../../Gridworks/src/sim.js:362-378`
- 端口与连接：`../../Gridworks/src/sim.js:382-468`
- 放置、删除与配方换线：`../../Gridworks/src/sim.js:481-540`
- 存档与离线：`../../Gridworks/src/sim.js:542-582`
- 状态灯：`../../Gridworks/src/sim.js:584-604`
- 电网与采集结算：`../../Gridworks/src/sim.js:606-750`
- 线路传输与反压：`../../Gridworks/src/sim.js:764-809`
- 地块与端口表现：`../../Gridworks/src/game.js:202-390`
- 10 Hz 主循环：`../../Gridworks/src/game.js:1394-1415`
- 采集和地图测试：`../../Gridworks/tests/test_sim.mjs`

### CoreGameplayLab

- 内容索引与验证：`../src/core/content_database.gd`
- 地点状态与库存容量：`../src/core/location_state.gd`
- 存档权威状态：`../src/core/game_state.gd`
- 勘测、采集、自动网络、离线推进：`../src/core/simulation_engine.gd`
- 玩家采集命令与事务：`../src/application/game.gd`
- 当前资源地点 UI：`../src/ui/main.gd`
- 采集内容：`../data/content.json`
- 产品尺度与美术方向：`Design_Direction_zh_CN.md`
- 核心循环：`core-game-loop.md`
