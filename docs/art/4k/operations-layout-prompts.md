# Operations layout board — 4K concept

## Intended use

This is a non-runtime, four-workspace visual direction board for the Territory,
Supply, Industry, and Engineering groups. It supports the 1920 x 1080 logical
to 3840 x 2160 physical 16:9 review contract. It is stored under
`docs/art/.gdignore` and must not become a Godot texture dependency.

The board’s shared language is a compact status shell, six purposeful global
navigation destinations, bounded workspaces, dense semantic rows, and clearly
named inner scrolling only where content can grow. It intentionally removes
the old permanent side rails and outer-page scroll from these conceptual
workspaces.

## Artifact and provenance

- `operations-layout-board.png`
- Generated dimensions: 1672 x 941 px (16:9-class landscape).
- Generation: built-in Codex ImageGen (`image_gen`), a new original generation
  with no input image, no copied game artwork, no external branding, and no
  runtime asset dependency.
- Provenance cache:
  `C:\\Users\\ZhaoJiyu\\.codex\\generated_images\\01a086b1-9e9b-7d40-acf4-cae590854f04\\exec-6c8ade62-1bfa-4498-9f1c-14d69d707228.png`
- Generated: 2026-09-10 01:52 local workspace time; copied unchanged into this
  document-art path.

## Prompt submitted verbatim

```text
Use case: ui-mockup
Asset type: coordinated 4-panel desktop game UI layout board, one 16:9 landscape image containing a strict 2x2 grid of four complete 16:9 workspace studies. Each study is a practical 1920x1080 logical UI intended to render 2x at 3840x2160.
Primary request: Produce a polished design-system board for an original orbital-industrial management game. All four panels share exactly the same compact full-width status header, a six-item global navigation row, navy/slate surfaces, 1px outlines, typography, icon language, button style, and spacing. Every panel is a complete workspace with no outer-page scrollbars, no persistent redundant global sidebars, and only explicitly bounded inner regions that could scroll when their actual lists grow.
Style/medium: high-fidelity shippable game UI mockups, front-on orthographic screen captures, Godot-friendly Control/PanelContainer geometry; flat layers, dense practical rows, restrained cyan focus glow, no skeuomorphic chrome, no people, no logos, no watermarks, no known game branding, no illustrated tourist prose, no invented dashboards or fake graphs.
Color palette: background #0c141c, panels #15222d, borders #304652, off-white text #e4ecef, cyan active #65d9d1, research/engineering violet #9181d8 only for selected dependency or phase accents. Use charcoal-blue industrial material, small cyan line icons. Chinese-capable sans-serif; title around 28px and body 16-18px at logical base.
Composition: exact 16:9 board, thin even gutters, four equal panels in a strict 2 by 2 grid. Each panel itself reads as a 16:9 screen compressed into the board, but all major regions are clear and fully visible. Do not make a presentation slide around the UIs; the four UIs themselves fill the board.
Shared shell in every panel: compact status header and exactly six equal-purpose navigation entries, with simple Chinese labels: "星系", "工业", "供应", "研究", "舰队", "工程". Highlight the relevant section per panel. No seven-item nav and no persistent left/right context rails.

Panel 1, upper left, Territory: title "星域态势". Under the shell, show three visible sibling local tabs "地图", "地点", "勘测". The workspace is 70% large bounded star-map viewport on the left with clean orbital paths, a few real location markers and subtle map controls; it is visibly pan/zoom capable. The 30% right selected-location intelligence panel shows only practical fields: survey state, site condition, available actions, and a compact open-site action. No sprawling cards.

Panel 2, upper right, Supply: title "物资与线路". Show local siblings "库存" and "路线". The left-majority panel is a dense, readable inventory table with exactly these column concepts: Material, Stored, Available, Reserved, Net. Use a few neutral industrial materials such as ore, alloy, electronics, propellant; only illustrative small quantities. The right selected-item/route details panel shows a selected material, one route or constraint, reservation reason and an action. Use a pinned search/filter row and table-local scrolling only. Do not show food, population, currency, consumer commerce, stock price charts, or invented production claims.

Panel 3, lower left, Industry: title "工业运营". Preserve an approved science-fiction industrial command-center voice: a narrow panoramic orbital foundry / blue-hour industrial image band across the upper workspace, then exactly four compact semantic metrics for extraction, active machines, power supply/demand, and construction queue. Below is a horizontal four-stage operational chain: "采集", "生产", "建造", "扩张". The bounded bottom region is a purposeful three-way split: alerts, planner, and material ledger side by side. Include real-looking action affordances and concise constraint rows; do not let panorama or metrics become giant empty cards; no outer scroll.

Panel 4, lower right, Engineering: title "工程阶段". Show the stage phase chooser as one compact horizontal strip of small adjacent phase buttons, never eight tall stacked cards. Main workspace is exactly a 45% left bounded phase-progress/dependency diagram with a few stage nodes and a coherent project silhouette, and a 55% right current-stage detail panel containing BOM, site readiness, supply constraint, stage progress, and one primary engineering action. The diagram and details must be visible together; all material/worksite values look like neutral illustrative placeholders, not canonical gameplay telemetry.

Text constraints: Chinese should be crisp and legible where used. Keep screen copy short. Use only these additional short labels where helpful: "地图", "地点", "勘测", "库存", "路线", "材料", "存储", "可用", "预留", "净值", "采集", "生产", "建造", "扩张", "警报", "规划", "账本", "当前阶段", "材料清单", "场址", "启动工程". No paragraphs, garbled pseudo-language, food, population, money, currency, or marketing slogans.
Output intent: one unified reference board for implementation review, not a runtime asset and not a literal copy of any supplied screen.
```

## Design review notes

### Accepted visual direction

- Territory makes the map itself the decision surface, with Map/Site/Survey as
  visible sibling contexts rather than a permanent inspector rail.
- Supply moves from large sequential cards to a scanable material ledger with a
  selected-item and route/constraint detail view beside it.
- Industry retains the foundry panorama and four-stage chain, but constrains the
  panorama and places alerts, planning, and ledger information side by side.
- Engineering puts phase navigation in a compact horizontal chooser and keeps
  a 45/55 phase diagram/current-stage decision split visible without stacking
  every phase as a tall card.

### Non-authoritative illustrative content

All quantities, item labels, planet labels, availability states, stages,
routes, project names, percentages, and values rendered by ImageGen are visual
placeholders. They are **not** proposed canonical gameplay metrics, content
definitions, telemetry, recipes, resource balances, construction state, or
progress data. In particular, this concept must not be used to add or imply
population, food, currency, consumer commerce, market prices, or other systems
that do not exist in the authoritative game model. Runtime implementation must
bind only existing snapshots, commands, locales, IDs, and original project art.

### Visual QA

Inspection confirms all four panels use a coherent navy/slate/cyan system,
repeat the six-way navigation, have visible local sibling navigation where
needed, and keep their major decision regions on one screen. The board contains
no persistent outer page scrollbar, no large unpurposed lower band, and no
fictional charting. It is an information-hierarchy reference, not a pixel-
perfect runtime capture; final 4K screenshots must verify actual text, data,
actions, and accessibility scale using Godot.
