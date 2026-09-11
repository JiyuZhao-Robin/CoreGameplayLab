# 地球地面细化

## 当前状态：纯平地，地貌工作暂停

2026-09-11 用户最新决定：暂时不做山脉、水域、森林及其它自然地貌，只保留完全平地与当前矿脉。`FactoryTerrain.FLAT_GROUND_ONLY` 是当前统一规则：地形分类与连续采样均为平地，检查器不再套用旧地形覆盖；山体光照和树木绘制关闭。新游戏与旧存档都适用，无需删除保存的种子、profile 或差量。

矿区仍使用原来的地理筛选和随机序列，避免关闭山水后重新排列矿脉。矿区显示、采矿设备和开采规则不变。树木/山体交互、Kenney 后续适配及巨型挖掘机选型暂停。素材和历史实现保留，但不作为当前验收目标。

当前聚焦验收入口为 `tests/factory_flat_ground_test.gd`：修改前真实 Earth 的全部 27 个矿区描述哈希保持一致；旧地形覆盖变为可建设平地；矿区清除差量、存档、道路和建筑碰撞仍有效。`--capture` 以真实 4K 画布输出 `artifacts/ui/flat-ground/`。下文 `earth_terrain_*` 和 `earth_foliage_test.gd` 的多地貌断言是暂停阶段的历史验收，不是当前纯平地验收。

主代理本次实际通过：`factory_flat_ground_test.gd`（headless 与真实 OpenGL 4K，已查看截图）、`factory_terrain_test.gd`（包含保留矿区生成地理的检查）、`factory_natural_rendering_test.gd`、`factory_landing_terrain_ui_test.gd`、`asset_conservation_test.gd`、`core_integrity_test.gd`，全部退出码为 0。未运行完整发布套件。

## 历史地貌实现与验证

2026-09-11：用户要求先把单一地球的山脉、水体、森林、草原做细。当前二维 Factory、道路工业、持续采矿和局部相机契约继续适用。

## 地貌与建造

新版以 `terrain_profile = "earth_v2"` 明确选择生成规则。连续高度、湿度、林木密度、水深和裸岩覆盖共同描述地面；建造使用同一采样器产生的五种既有地形类型。水体与山地阻挡建造，草原、林地与沙地遵循现有可建规则；此轮没有新增伐木经济或地形改造命令。

地区级地貌由带种子的山脊、河谷、湖盆和海岸曲线组织，局部噪声细化坡面、岸线与生态。河流由源头通向湖泊，山脉保留低矮山口；森林根据生态条件渐变为疏林与草原。这里是适合工业布局的地球风格区域，并非真实地球 GIS，也不是水力侵蚀或流体模拟。

## 存档与开局

新地球使用新规则；不带新 profile 的存档保留历史地形。profile 与种子一起经过世界归一化、存档和 Factory 快照传递。初始 144×96 可建区域及铁铜矿位置保留，外围通过渐变接回自然地貌，避免已有开局设备规格与道路测试失效。

## 显示

山坡明暗、裸岩、林地底色和水深来自权威连续采样。正式 Factory 渲染器负责显示，不单独维护美术版地理。按用户最新选择，树冠采用 Kenney Nature Kit 2.1 原模型渲染的透明 2×2 图集；完整原包、72 个树木/树桩/木材 GLB、CC0 许可和派生场景保存在 `assets/ui/factory/natural/kenney_nature/`。派生材质适配为自然绿，原模型不改动。此前 AI 树冠保留来源记录，但已不被正式植被引用。照片地表沿用原有来源记录。

原有每屏约 8192 格、96 个缓存区块的预算保留；植被采用区块批次，并避开建筑、道路和矿区。独立预览也使用正式画布，仅提供地貌观察导航，不读写玩家存档。

## 验证

Kenney 替换后，主代理重新完成 Godot 导入（开启 mipmap）、`earth_foliage_test.gd` 与真实 OpenGL 4K `earth_terrain_visual_test.gd`，均退出 0；已查看新的林缘和山麓画面。以下更广的检查是同日此前地形实现阶段的结果，本次纯美术替换没有重复运行全部检查。

2026-09-11 主代理在 Godot 4.6.3 实际串行运行通过：

- `earth_terrain_test.gd`：确定性、旧生成器固定样本、连通水域与山带、可建山口、坐标平移、连续场与安全区渐变。
- `earth_terrain_integration_test.gd`：真实新游戏、存档/快照一致、旧存档不升级、水体/山脉拒绝落地且不扣资产、11×11 开局矿机。
- `earth_foliage_test.gd`：真实树冠、建筑/幽灵/道路/不规则矿区避让、零密度无树、静止缓存与 96 区块上限。
- `earth_terrain_visual_test.gd`：真实 OpenGL 3840×2160 草地、林缘、水岸和山麓截图；局部相机、区块连续性及缓存复用。已人工查看画面并加强岩面坡度明暗。原图位于 `artifacts/ui/earth-terrain/`，`-review.png` 为引擎生成的缩小查看副本。
- 旧地形、自然地表渲染、开局内容、资产守恒、内容/规划器、核心完整性、UI Domain、固定布局/窗口尺寸矩阵与缩放契约定向测试。

实际运行的 `factory_grid_simulation_test.gd` 未通过：它仍断言旧尺寸、3×3 矿机、手动端口与现场施工规则，且旧裁图夹具访问失效实体。未将这些过期合同重新接回产品，也不声称全测试通过。现行契约的本轮地形与开局路径由上述新测试覆盖。

独立预览入口为 `demos/earth_terrain/earth_terrain_preview.tscn`，使用同一正式渲染器。运行方式见[预览说明](../demos/earth_terrain/README.md)。当前树冠由 Blender 渲染 Kenney 原模型，复现方式与哈希见[Kenney 素材来源](../assets/ui/factory/natural/kenney_nature/PROVENANCE.md)。

完整发布验收、满负载性能基准与桥梁仍为独立范围。下述追加要求把可采集树木和可开挖山体纳入地表工作的待实现部分；此前截图与测试不代表这些交互已经完成。

## 追加要求：可采集树木与可开挖山体

用户明确要求参考 Factorio、Dyson Sphere Program 的可采集自然对象，以及 Captain of Industry 的可开挖山体。当前树冠仅为显示对象，建筑/道路避让没有产生采集收益和永久清除记录；山体也只有采样高度与阻挡分类。不得把这些现状称为完整交互地形。

- **树木的完成标准**：每棵树有稳定身份、位置、采集产物和采集状态；支持选中和清除采集，物品进入现有 Location 库存，重复操作不能重复产物。伐木结果跨保存/加载、相机缩放与建筑拆除保留。画面批量绘制可以保留，但生成身份不能随 LOD 改变。
- **山体的完成标准**：局部区域拥有实际高度、材料层和可移除数量；开挖消耗局部物料、产生对应资源、形成可见缺口/坡面，并同步更新建造与通行判断。挖去山体中间一段应能分开两侧地形，而非整座山统一消失。仅将 `MOUNTAIN` 改为 `PLAIN` 的操作不满足这一要求。
- **实现架构建议，尚未落地**：自然对象目录与采集差量；高度/材料层与挖掘差量；两者共享现有事务、命令收据、库存容量与存档边界。开挖深度、设备执行、运输及滑坡规则需在实现时具体化，不能把本条直接宣称为完整 COI 物理系统。

参考证据：[Factorio 树木原型](https://lua-api.factorio.com/latest/prototypes/TreePrototype.html)、[树木交互开发日志](https://www.factorio.com/blog/post/fff-86)、[DSP Drone Clearing 开源模组](https://github.com/GreyHak/dsp-drone-clearing)、[Captain of Industry 地形表示、材料层与物理开发日志](https://coigame.com/Blog/cd-35)。DSP 模组是研究其采集接口的材料，不是原版完整源码或原版自动伐木功能的证明。
