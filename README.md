# Helios Core Gameplay Lab

这是从主项目拆出的独立 Godot 单恒星系工业管理游戏核心版本。它保留内容数据、存档、离线模拟和纯控件操作界面；Factory 使用项目内已入库、带生成来源记录的地形、道路、建筑和物品资产。

当前 Save Schema 为 39，内容版本为 `1.32.0`。schema 24–39 采用显式逐版本迁移；旧全局库存迁入 `earth_orbit`，Location、物流、在途 Shipment、舰船装配与研发继续保留。1.29 的地点级采矿、Production Line、Extraction Network 和普通 Construction 已迁入只读历史归档，schema 38 又移除了舰船采矿/常驻打捞职责，schema 39 为旧存档中已调查的远端地点补记有限调查前哨包；新的普通工业权威是方格实体工厂。旧四巨构状态只进入历史归档，不会伪装成新终局进度；逐物品消费统计从 schema 35 开始累计。

## 设计文档

- [正式设计方向](docs/Design_Direction_zh_CN.md)：已确认的产品定位、系统边界和当前 Factory 原则。
- [内容同步状态](docs/Content_Synchronization_zh_CN.md)：当前已批准、已实现、已验证、待设计和历史资料的区分。
- [星球共享库存与道路工业](docs/Planetary_Industry_Roads_Design_zh_CN.md)：当前 Factory 的详细规则、数据契约和定向验证记录。
- [历史核心玩法审计](docs/Core_Gameplay_Implementation_Review_zh_CN.md)：1.21 / schema 27 的迁移背景，不是当前实现状态。

不要将历史审计、旧计划或目标方向误报为当前功能；当前代码与实际重跑的聚焦测试才是实现事实。

## 直接启动

1. 打开 Godot 项目管理器，点击“导入”。
2. 选择本仓库中的 `project.godot`，然后点击“导入并编辑”。
3. 按 **F6** 运行当前场景，或按 **F5** 运行项目。

也可以在仓库根目录运行：

```bash
godot --path .
```

## 当前玩法流程

1. 打开 **工业与建设 / Factory Grid**，先把库存中的星球开发核心部署到合法地块。核心提供 400 kW，并一次性发放两矿机、两锻炉和一台自动制造机。
2. 在底部 Palette 选择建筑成品并部署；没有成品时放置幽灵，待共享 Location 库存获得该成品后自动部署。普通建筑没有现场建材施工条。
3. 铺设道路，让核心、矿机、机器和仓库接触同一条道路网络。道路同时连接本地电力与自动运输；没有本地 CARGO/POWER 端口拖线。
4. 为机器选择配方。机器在输入、输出空间、电力或道路服务不足时会显示实际阻塞原因；余料通过道路进入仓库接入的星球共享库存。
5. 在地点 **物流** 页配置跨地点航运和运输舰。航运从一个 Location 库存运往另一个 Location 库存；道路不改变星际航线或 ETA。
6. 在 **研发** 推进项目，在 **舰队** 设计、建造并编组战斗、探索和运输舰。舰船不承担采矿、施工或常驻打捞。
7. 使用探索编队按 `UNKNOWN → DETECTED → SURVEYED → DEEP_SURVEYED` 调查远端地点，并运输开发核心和建筑成品建立远端工业。
8. 推进高级工业、研究与唯一 `stellar_energy` 项目。完整戴森球壳和第二恒星系不属于当前版本范围。

当前已实现和尚待实现的范围不在 README 复制维护，统一见[内容同步状态](docs/Content_Synchronization_zh_CN.md)。该页也说明哪些测试记录只是历史证据，哪些能力仍需要重新验证。

## 验证

可选的聚合发布检查：

```bash
./tests/run_core_complete.sh
```

脚本验证 JSON、内容合同、若干领域/界面检查和资产守恒；它**不**运行已退役的 Golden Path 或 J1–J10 runtime 链。日常功能修改应先运行受影响的聚焦测试，完整脚本仅在明确需要时执行。
