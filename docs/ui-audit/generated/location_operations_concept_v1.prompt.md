# 地点运营总览概念图

Mode: built-in image_gen. Single UI concept; values are illustrative.

```text
Use case: ui-mockup
Asset type: polished desktop strategy/factory game UI design concept, single full screen.
Primary request: Create a high fidelity, implementable Chinese-language "地点运营总览" screen for the existing sci-fi factory game 赫利俄斯. Merge formerly separate overview, resources and industry tabs into one dense yet readable dashboard. 16:9 landscape, composed on a 1920x1080 logical design grid, ideally render at 3840x2160. Straight-on UI only.
Style: refined dark navy industrial command console, crisp thin slate borders, flat restrained surfaces, near-square small-radius corners, cyan interactive highlights, off-white legible typography, amber bottleneck badges. Native-looking Chinese sans serif, aligned tabular numbers. No fantasy HUD clutter, no huge blank boxes, no decorative charts.
Layout: top 5% height is compact global bar with 赫利俄斯 left, day/time and speed controls right. Next 5% is primary navigation "星域  工业  供应  科研  舰队  工程", 星域 selected. Next 4% is subnavigation "恒星系  地点管理  勘测", 地点管理 selected, location picker right. Do NOT include additional tabs 总览/资源/工业 inside the content.
Content heading about 7% height: small planet/location emblem, "地球轨道" prominent, "太阳系 · 已勘测" secondary. Right-aligned actions "深度勘测" "进入工厂" "安排运输". Small descriptor "地点运营总览".
Metric band about 9% height: four compact equal metric blocks "供电 / 负载" with "120 / 96 kW" and 80% utilization bar; "工业运行" with "18 运行 · 2 停机"; "本地仓储" with "68%" and thin capacity bar; "任务 / 运输" with "3 建造 · 2 在途".
Remaining main dashboard: two columns in 55:45 ratio, two rows. Upper row about 34% of screen height and lower row about 28%. Modest 16px-like gutters.
Upper left panel "资源情报", right action "查看矿区 →". Dense table with columns "资源" "品位" "勘测潜力" "开发状态". 5 well-aligned rows of small original readable ore/ice icons and names 铁矿 铜矿 硅矿 钛矿 水冰, plausible illustrative values with /h units. Clearly label the table footer "勘测潜力 ≠ 实际产量". Four rows 已开发 or 可开发, one 待深度勘测. Keep mine potential separate from owned inventory.
Upper right panel "工业运行", action "打开生产管理 →". Small facility icon strip and a compact list of three production lines "铁锭生产" "铜锭生产" "基础零件", actual output rates and status badges. Lower part of this panel contains amber actionable alert rows "冶炼区供电不足" with "查看电网 →" and "装配区等待铜锭" with "定位机器 →". Table aligned; no large pictorial factory canvas.
Lower left panel "本地库存", compact filter pills "全部  原料  零件  补给". Table columns "物品" "库存" "在途" "状态", rows 铁锭 铜锭 电子元件 维修材料 化学推进剂, small original item icons, numerical stock, incoming amounts, sufficient/low stock text badges. At least one low stock row amber. Footer "打开仓库 →".
Lower right panel "本地任务", rows with compact icons, labels, progress bars and ETA: "建造 · 电弧熔炉" 65%, "运输 · 铜锭补给" 42%, "勘测 · 深度勘测" 待分配勘测舰; include "配置勘测舰 →" for the blocked task. Bottom concise "驻留舰队 2" with "查看舰队 →".
Bottom environment strip about 5% height: "环境条件" followed by compact key-value chips "重力 0.00 g" "真空" "辐射 低" "日照 1.00" "建设难度 ×1.25", right "详细情报 →". Final tiny footer "概念设计 · 示例数据" and a discreet 返回 action.
Visual hierarchy: tables and actionable status dominate, no three tall equal-width cards. All sections fit within one screen, all primary actions visible. Use small ore/building icons for scanability, a very small Earth emblem only, no huge planet illustration. Keep clear readable text and consistent type scale; do not shrink labels to pack excessive data. Accurate Chinese headings as specified, no lorem ipsum. Original non-branded icons. This is a design proposal with illustrative data, not a claim of live game state.
Color palette: background #0b141b, panel #10202b, elevated #152a35, borders #304a58, cyan #65d6d0, text #dde8ed, muted #8aa1ad, amber #e4b45e. Restrained teal glow only on selected controls.
Constraints: one complete screen, no device frame, no browser chrome, no perspective, no annotations outside the UI, no watermark, no graphs without meaning, no repeated headers, no clipped footer or buttons.
```
