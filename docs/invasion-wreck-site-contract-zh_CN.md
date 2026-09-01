# 入侵战后有限残骸点接口

更新时间：2026-09-01

## 已确认边界

- 舰船不具备采矿、气体采集、残骸采集或施工能力。
- 战斗即时掉落与远征产品继续进入编队 `recovered` 货舱，并按真实货舱/仓储容量卸载。
- 打捞不作为长期可重复的舰队职业或活动 Domain。
- 未来只有入侵事件结束后才能生成残骸点；打捞与分析消耗有限工作量，工作量耗尽后活动点消失。

## 当前接口

领域入口位于 `src/core/wreck_site_system.gd`：

```gdscript
create_after_invasion(state, location_id, invasion_event_id, total_work, metadata)
apply_work(state, site_id, "SALVAGE" | "ANALYSIS", requested_work)
```

`create_after_invasion` 强制要求地点、入侵事件 ID 和正数工作量。活动记录只保存来源、地点、总工作量、剩余工作量、两种已完成工作和元数据，不含 `ship_ids` 或 `assigned_ship_ids`。

`apply_work` 最多接受当前剩余工作量。`SALVAGE` 与 `ANALYSIS` 共用同一个 `remaining_work`；归零时状态快照进入 `wreck_site_history`，活动记录从 `wreck_sites` 删除。之后再次提交工作会返回 `SITE_UNAVAILABLE`。

## 暂不实现

- 入侵事件生成器、战役 UI 与战场位置表现。
- 打捞设施、分析设施、人员、机器人、工时来源与风险事件。
- 残骸组成、所有权、污染、敌方增援、产物和科技分析表。
- 任何基于舰船采矿/打捞数值的效率公式。

当前 `outputs` 固定为空字典。后续只能在明确上述资产与风险归属后接入奖励结算，不能用该接口直接凭空加库存。
