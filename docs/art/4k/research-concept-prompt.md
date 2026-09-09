# Research Command 4K concept

## Intended use

Foundational visual-direction reference for the proposed Research Command
workspace. This is a non-runtime concept under `docs/art/.gdignore`; it guides
the 1920 x 1080 logical / 3840 x 2160 physical layout review and does not add a
texture dependency to Godot.

The image demonstrates a compact system header and six-item global navigation,
one current-program command rail, a bounded research graph, and a selected
project inspector. The graph and inspector are visible together without an
outer page scrollbar. It deliberately replaces a horizontal all-project action
wall with node actions and a contextual inspector.

## Artifact

- `research-command-concept.png`
- Generated dimensions: 1672 x 941 px (16:9-class landscape)
- Generation method: built-in Codex ImageGen (`image_gen`), new generation,
  no input or copied game art.
- Provenance cache: `C:\\Users\\ZhaoJiyu\\.codex\\generated_images\\01a086b1-9e9b-7d40-acf4-cae590854f04\\exec-a1587bd2-a234-466c-b80c-f3d75fe3f14b.png`
- Generated: 2026-09-10 01:48 local workspace time; copied unchanged into this
  document-art path.

## Prompt submitted verbatim

```text
Use case: ui-mockup
Asset type: foundational in-game Research Command workspace concept for a Godot 4 game UI, 16:9 widescreen, designed as a 1920x1080 logical layout that will render at 2x on 3840x2160.
Primary request: Create one polished, implementable desktop game UI screen for an original orbital-industrial science command center. It must communicate a dense but calm research workflow: status shell, current program control, research dependency graph, and selected-project inspector.
Scene/backdrop: flat dark navy graphite application surfaces, no illustrated scene background. Fine subdued technical grid only within the graph viewport.
Subject and hierarchy: (1) a full-width 48px logical status header with compact system readouts; (2) immediately below it six equally purposeful global navigation entries at about 44px logical height: Territory, Industry, Supply, Research, Fleet, Engineering, with Research visibly selected; (3) a compact 96px-high Research Command title/current-project rail with an honest stage-progress bar, one blocker/cost summary, and one primary action; (4) below, a bounded main workspace: research graph at approximately 70% width on the left and a selected-project inspector at approximately 30% width on the right. The graph must visibly support pan/zoom through small controls in its own top edge. It contains a handful of compact dependency nodes with thin cyan and restrained violet connectors, unlocked/blocked/active state colors, but no long horizontal all-project button strip. The inspector visibly includes prerequisites, current stage progress, material costs, an action button, and a short reason/status note. All regions must be visible with no outer-page scrollbar. Use dense rows and modest padding; no enormous empty cards, no redundant sidebars, no tourist prose.
Style/medium: high-fidelity shippable UI mockup, crisp Godot-friendly Control/PanelContainer geometry, flat layered panels, 1px outlines, restrained glow only on selected/active state, no skeuomorphic chrome, no logos or known game branding.
Typography: use a clean Chinese-capable sans-serif, crisp and legible. Include only these exact short Chinese labels where text appears: "研究指挥", "研究", "当前项目", "阶段进度", "先决条件", "材料成本", "启动研究", "已阻塞", "可用". Keep secondary values as simple believable numerals and short labels; do not add paragraphs, garbled text, pseudo-language, watermarks, or slogans.
Color palette: background #0c141c, panels #15222d, borders #304652, off-white text #e4ecef, cyan active accents #65d9d1, restrained research-violet #9181d8. Text hierarchy should read as 28px page title and 16-18px body at base logical scale, with clear contrast.
Composition/framing: exact full-screen 16:9 UI capture, front-on, all edges visible. Graph and inspector have a strong 70/30 split. Make the research graph the visual focal area, but ensure the inspector is functional and information-dense.
Constraints: original UI only; feasible with standard Godot Controls; no external game assets; no people; no 3D scenery; no mascot; no logos; no watermark; no outer page scrolling; no oversized empty lower-right panel.
```

## Visual QA and implementation notes

Inspection confirms a clear 70/30 graph/inspector split, six global navigation
destinations, one compact current-project rail, visible prerequisite/progress/
cost/action information, and a graph-local zoom control. The generated Chinese
labels are legible in the reference at normal viewing scale; implementation
must still source all real copy from the localization catalogs rather than from
this bitmap.

Treat the artwork as layout and hierarchy direction, not a pixel-perfect scene
or a license to add synthetic telemetry. Use standard Controls, a bounded
GraphEdit, and nested scrolling only for truly growing lists. Verify final
physical 4K captures separately because this concept itself is intentionally a
16:9 reference rather than a runtime screenshot.
