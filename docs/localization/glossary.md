# UI 本地化术语表与 Key 契约

更新时间：2026-08-28  
适用范围：`src/ui`、玩家可见的 `src/application` 通知、可能进入诊断界面的 `src/core` 文本、场景文本和双语目录。

## Key 契约

- 稳定 key 只能是 `I18n.core("literal.key")` 或 `I18n.t("literal.key")` 的字面量首参数。
- `I18n.core` 对应 `core_ui`，`I18n.t` 对应 `ui`；稳定 key 必须同时有非空 `zh_CN` 与 `en` 文案。
- `I18n.inline(text)` 是遗留文本替换，输入可以是运行时字符串，不构成稳定 key，也不得计入迁移完成率。
- 英文 fallback 只能保障故障可读性，不能证明英文目录覆盖。
- 动态 key（例如 `"status.%s" % status`）必须由单独的枚举契约证明所有展开值；静态审计只标记为 `REVIEW`。
- 参数使用 `%s`、`%d`、`%f` 等结构化占位符；中英文的占位符顺序和类型必须一致。不要拼接完整句子的半句翻译。
- 内容实体 identity 使用稳定 ID；名称与说明通过 `I18n.content` 取得，不把翻译写进存档。
- `.tscn` 中的 `text`、`tooltip_text`、`placeholder_text` 不直接保存玩家文案；应在脚本中从稳定 key 赋值，或使用另有审计契约的 Translation 资源。

## 核心术语

| 概念 / ID 语义 | English | 简体中文 | 使用说明 |
| --- | --- | --- | --- |
| product / item | Product | 产品 | 工业系统中的可库存产物；交易语境才称 Goods / 商品 |
| location | Location | 地点 | 统一包含轨道、基地、小行星带、拉格朗日点和具体天体；不要一律写成“星球” |
| system | System | 恒星系 | 当前产品范围只有 Sol，但 UI 仍显示所属恒星系 |
| inventory | Inventory | 库存 | 某地点实际持有的物品集合 |
| available | Available | 可用 | 库存中未被承诺或预留的部分 |
| reserved | Reserved | 预留 | 已有明确所有权声明、尚未消费的库存 |
| project staging | Project Staging | 项目暂存 | 已交付给建设、研发或巨构项目的物资 |
| in transit | In Transit | 在途 | 已离开来源、尚未进入目的地的实体货物 |
| demand | Demand | 需求 | 持续或项目型物资需求；不要与已消费量混用 |
| supply | Supply | 供给 | 可向生产、物流或项目提供的实际流量 |
| net flow | Net Flow | 净流量 | 生产与进口减去消费与出口后的时间流量 |
| factory | Factory | 工厂 | 承载生产线的工业设施，不等同于单台装置 |
| facility | Facility | 设施 | 工厂、电力、科研、船坞、物流等基础设施统称 |
| production line | Production Line | 生产线 | 工厂内具有独立控制与状态的运行单元 |
| production device | Production Device | 生产装置 | 安装后提供真实制造能力的资本设备 |
| production method | Production Method | 生产方式 | 生产输入、输出、设备和环境约束的规则定义 |
| operation | Operation | 作业 | 可运行、暂停或阻塞的持续执行实例 |
| project | Project | 项目 | 有材料承诺、阶段、工期和完成边界的建设或研发工作 |
| construction | Construction | 建设 | 共用有限建设能力的项目系统；具体现场动作可称“施工” |
| construction capacity | Construction Capacity | 建设能力 | 项目争用的持续吞吐，不是库存物品 |
| research | Research | 研发 | 材料、研究容量、实验和实地测试共同驱动的项目系统 |
| technology | Technology | 技术 | 已掌握并持续生效的能力或组织方式 |
| spillover | Technology Spillover | 技术外溢 | 项目过程中提前形成的可用技术成果 |
| ship | Ship | 舰船 | 具有永久 identity、状态、装配和生命周期的实体资产；玩家正文不使用“飞船”泛称 |
| fleet | Fleet | 舰队 | 已分配舰船及其条令、补给和任务所有权 |
| loadout | Loadout | 装配方案 | 舰体模块配置；与已安装的实体模块区分 |
| survey | Survey | 勘测 | 推进地点情报层级的任务，不与 Expedition / 远征混用 |
| expedition | Expedition | 远征 | 舰队执行的路线、事件和战斗任务 |
| logistics | Logistics | 物流 | 路线、运力、枢纽、装卸、燃料和在途资产系统 |
| shipment | Shipment | 运输批次 | 一次具有来源、目的地、货物和状态的实体运输 |
| blocker | Blocker | 阻塞原因 | 玩家当前无法继续的结构化首要原因 |
| diagnostics | Diagnostics | 诊断 | 解释 What / Why / Resolution / Navigation 的只读界面 |
| guidance | Guidance | 引导 | 由真实状态和 blocker 驱动的下一步建议，不记录“按钮点过” |
| megastructure | Megastructure | 巨构 | 当前唯一恒星能源终局工程；玩家中文不显示 `MEGA` |
| phase / stage | Phase / Stage | 阶段 | 同一界面内选定一种英文词；中文统一显示“阶段” |
| bill of materials | Bill of Materials | 物料清单 | 高级诊断可在首次出现时附注 `BOM`，普通按钮和正文不用裸缩写 |
| cycle | Cycle | 周期 | 生产重复边界；中文速率写“周期/秒”或更适合玩家的“单位/小时” |

## 状态与语气

- 领域枚举如 `RUNNING`、`BLOCKED_OUTPUT`、`DEEP_SURVEYED` 只存在于状态与代码中；玩家界面显示本地化状态词。
- Running / 运行中，Waiting / 等待，Blocked / 阻塞，Paused / 已暂停，Completed / 已完成，Cancelled / 已取消。
- 状态句先说明结果，再说明原因与解决入口。不要只显示枚举或颜色。
- 危险操作使用明确动词和对象，例如“取消当前建设阶段”；不要只写“确认”。
- 英文采用 sentence case；导航和短标题可用 title case，但同一层级保持一致。
- 中文与数字/拉丁缩写之间保留必要空格；单位采用 `10 kW`、`2.5 h`，百分号不加空格。

## 已知迁移债务

当前生产代码实际引用的稳定 `core_ui` / `ui` key 已实现双语覆盖，运行时缺键为 0；`src/ui`、场景以及 `src/application/game.gd` 的玩家文本硬编码均为 0，`I18n.inline` 也已归零。682 个当前未引用的中文历史目录条目仍没有英文对应项，应按 Dead UI / 功能复用结果决定删除或补译，不能把历史 catalog 清理与当前玩家表面的运行时门禁混为一谈。

建设历史使用 `Reserved / 预留`、`Consumed / 已消耗`、`In-transit / 在途`；巨构对玩家显示 `Project state / 工程状态`，不使用开发语气的 `Gameplay state / 玩法状态`。`LOCKED`、`BUILDING`、`SITE_PREPARATION`、`WAITING_MATERIAL`、`INTEGRATION`、`COMMISSIONING`、`COMPLETED` 以及运输的 `IN_TRANSIT`、`BLOCKED_DESTINATION` 都必须在双语 `core_ui.status.*` 动态状态契约中有明确值。

研发归一化状态使用通用项目语言：`ACTIVE / 运行中`、`WAITING_MATERIAL / 等待材料`、`WAITING_FACILITY / 等待设施`、`WAITING_KNOWLEDGE / 等待知识积累`、`WAITING_FIELD_TEST / 等待实地测试`、`WAITING_PROTOTYPE / 等待原型`。共享 `ACTIVE` 不使用舰船生命周期专用的“现役”；舰船若需表达服役状态，应使用舰船上下文专用 key。

审计把两类风险分开：生产代码实际引用缺语言仍为 `ERROR`；未引用的历史目录不对称为 `REVIEW`。历史条目一旦重新接入稳定 API，就会自动升级为运行时缺键错误。

运行审计：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' --script res://tools/ui_localization_audit.gd -- --strict --no-persistence
```

审计退出码：稳定 key 缺失、空文案、英文稳定文案含 CJK、占位符不匹配或目录不可读时为 `1`；硬编码、`I18n.inline`、动态 key 和术语问题分别记录为 `WARN` / `REVIEW`。

运行审计器自身测试：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_localization_audit_test.tscn -- --no-persistence --locale=en
```
