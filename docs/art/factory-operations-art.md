# Factory Operations Art

日期：2026-09-10  
范围：Factory Operations Overview 的原创位图环境素材。

## 交付物

| 文件 | 尺寸 | 用途 |
| --- | ---: | --- |
| `assets/ui/factory/operations_art/regolith_tile.png` | 1254 × 1254 | 工厂画布可平铺的深蓝灰玄武岩/风化层底材。它应置于程序网格、资源田、建筑和线路之下，并以低不透明度使用。 |
| `assets/ui/factory/operations_art/foundry_panorama.png` | 1672 × 941 | Operations Overview 的宽幅环境横幅。左侧保留较暗的低细节区域，承载统辖中枢标题与地点遥测；右侧是工业活动。任务说明保留在独立任务系统。 |

两张图均由内置 ImageGen 在本项目任务中原创生成；未使用外部图像、Logo、文字或第三方游戏素材。文件内保留生成工具的 C2PA 来源元数据。

## 使用边界

- `regolith_tile.png` 是环境材质，不承载格线、状态、资源种类或可交互命中信息；这些仍由 Godot 程序层和语义 UI 绘制。
- `foundry_panorama.png` 是固定的概览氛围图，不替代可交互的 Factory Canvas。叠加深色面板或渐变时应保留左侧留白，避免将正文压在明亮厂房上。
- 青色运行光、琥珀建设光、警告和瓶颈状态必须继续由主题 token、glyph 和程序效果表达，不能依赖位图中的颜色。

## 生成记录

工具：内置 `image_gen`（默认 ImageGen 工作流；生成元数据标识为 `gpt-image` 2.0）。

### `regolith_tile.png`

```text
Use case: stylized-concept
Asset type: seamless repeating canvas texture for a desktop factory-planning game
Primary request: Create one polished original seamless square tile texture of a quiet dark blue-gray basalt and regolith industrial planet surface, seen strictly from directly overhead.
Scene/backdrop: empty ground surface only, with a subtle fractured basalt grain, faint dusty regolith variation, and only a few shallow mineral flecks.
Style/medium: premium game-environment material texture; restrained semi-realistic painted PBR surface, very low visual noise.
Composition/framing: perfectly even coverage and density across all edges; designed to repeat in every direction without visible seams, focal point, border, vignette, or perspective.
Lighting/mood: diffuse cool blue-hour light, nearly shadowless.
Color palette: charcoal, desaturated navy, blue-gray; no bright accents.
Materials/textures: dry basalt plates, fine powder, tiny embedded specks; low contrast.
Constraints: square, tileable, no objects, no structures, no machinery, no roads, no grid lines, no symbols, no text, no logos, no UI, no horizon, no cast shadows, no watermark.
```

视觉检查：严格顶视、没有物体、文字、格线或边框；整体灰阶克制。生成模型无法数学证明边缘连续性，因此接入时仍应在 Factory Canvas 中做四向重复截图检查。

### `foundry_panorama.png`

```text
Use case: stylized-concept
Asset type: wide operations-overview banner for a desktop space-industrial strategy game; original bitmap art, not a UI mockup
Primary request: Create a polished wide 16:9 panorama of an orbital/planet-surface factory colony at blue hour.
Scene/backdrop: a harsh dark basalt industrial surface under a cool deep-blue twilight sky; distant low haze, no visible planet dominating the scene.
Subject: believable macro-scale graphite refinery buildings, storage modules, gantry cranes, cargo platforms, pipes and power infrastructure. Place the substantial machinery and visual activity across the right two-thirds. Use the left third as deliberately dark, open, calm environmental negative space suitable for a translucent UI overlay; it may contain only a distant faint service road or very subtle terrain texture.
Style/medium: premium original sci-fi strategy-game environment illustration, elevated oblique aerial view; physically convincing hard-surface industrial design, high craft, not photoreal, no isometric icon sheet.
Composition/framing: true wide panoramic framing; clear depth layers, no central hero object, no cluttered foreground at left, machinery must not cross into the left UI-safe area.
Lighting/mood: cool cyan operating lights and restrained warm amber from a few molten furnace apertures and crane work lights; moody, capable, mature industrial civilization; readable at low opacity behind UI.
Color palette: graphite black, deep navy, blue-gray, cool cyan, small accents of muted amber; no saturated rainbow colors.
Materials/textures: brushed steel, dark ceramic panels, weathered basalt, glass telemetry strips, steam/dust hints.
Text (verbatim): none
Constraints: original art only; no characters, no spaceships as focal subject, no logos, no signs, no readable text, no interface panels, no grids, no watermark. Avoid bright glare and avoid visual noise in the left third.
```

视觉检查：16:9 宽幅构图，左侧为可读的深色环境留白；右侧厂房、传送设施、起重机、青色运行灯和克制琥珀炉光形成层次。没有人物、Logo、可读文字或 UI 元素。
