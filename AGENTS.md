# Agent instructions

## Multi-agent collaboration

This repository uses a primary-agent integration model. For every non-trivial
task, the primary agent owns the final result, delegates independent work when
there are at least two genuinely independent tracks and delegation materially
reduces elapsed time, waits for delegated work, reviews all results, resolves
integration issues, and runs the final verification.

Every primary agent and subagent working in this repository must read and follow
`docs/parallel-agent-playbook.md` before orchestrating, accepting, or beginning
delegated work. Its task-packet, ownership, handoff, and integration rules are
part of this repository's definition of done.

### Delegation policy

- Use subagents when a task contains two or more independent exploration,
  implementation, test, documentation, or review tracks and the coordination
  cost is lower than doing the work locally. If capacity is unavailable or the
  work is too small to benefit, the primary agent may continue locally.
- Prefer three bounded subagents when three useful independent tracks exist.
  Do not invent filler work merely to occupy all slots.
- The primary agent remains the integrator. It owns scope, shared contracts,
  sequencing, final diff review, and the final test run.
- Subagents must not spawn additional agents unless the primary agent explicitly
  delegates orchestration authority to them.
- Prefer the project roles by purpose when the client supports custom-agent
  selection: `project_explorer` for read-only mapping, `module_worker` for a
  bounded write surface, and `integration_reviewer` for final read-only review.
  On clients that cannot select those roles, reproduce their constraints in the
  task packet; the packet and path ownership remain authoritative.
- Parallelize read-heavy discovery, test-gap analysis, log triage, and review
  freely. Parallelize writes only after assigning non-overlapping path ownership.
- When useful work cannot be separated without editing the same files, use one
  writer and parallel read-only reviewers instead of concurrent writers.

### Required task packet

Before assigning a writing subagent, state all of the following in its task:

- objective and observable completion criteria;
- owned files or directories;
- forbidden files or directories;
- pre-existing dirty files inside the owned paths, or an explicit statement that
  there are none;
- public contracts that must remain stable;
- tests the subagent must run;
- repository paths that verification may write, including generated content,
  `.godot`, screenshots, logs, and test artifacts;
- the required handoff: changed files, tests, assumptions, and remaining risks.

An assignment without explicit write ownership is read-only. A subagent that
discovers a necessary edit outside its ownership must stop expanding scope and
return an interface or integration request to the primary agent.

### Shared-checkout safety

- Assume subagents in one session share the same checkout and see each other's
  edits immediately.
- Before spawning, the primary agent records a wave ownership map containing
  agent, owned paths, pre-existing dirty paths, and verification side effects.
- Never assign overlapping files or ancestor/descendant directories to two
  writing agents at the same time.
- Before delegating, inspect `git status --short`. Existing modifications and
  untracked files belong to the user or another active task and must be preserved.
- Record a pre-wave status/diff summary. Do not assign an already-dirty path to a
  writing agent unless the task explicitly includes that existing work and says
  how the final diff will distinguish pre-existing changes.
- Ownership is released only after the primary agent receives the handoff or
  confirms that an interrupted agent has stopped. Do not integrate, reassign, or
  begin a new wave on paths still owned by an active agent.
- Do not create commits, branches, stashes, resets, or worktrees unless the user
  requested that Git operation or the task explicitly includes repository setup.
- When Git operations are already authorized, substantial parallel
  implementations that would overlap should use separate Codex worktree chats
  based on the same committed baseline. Otherwise fall back to one shared-checkout
  writer plus read-only reviewers. Each retained worktree uses its own branch.
- A read-only agent must not run commands that can write the repository. In a
  shared checkout, serialize Godot runs, imports, exports, content generators, and
  tests that write fixed logs or artifacts. Use separate worktrees and per-run
  output roots when those commands must run concurrently.
- Keep generated evidence, screenshots, archives, caches, and `.godot` output out
  of commits unless the task explicitly requires them.

### Exclusive integration surfaces

Treat these as exclusive-owner files during a parallel wave:

- `src/ui/main.gd`
- `src/ui/main.tscn`
- `src/ui/ui_theme_tokens.gd`
- `src/ui/ui_navigation_state.gd`
- `src/ui/components/game_shell.gd`
- `src/application/game.gd`
- `src/core/game_state.gd`
- `src/core/game_version.gd`
- `src/core/game_state_transaction.gd`
- `src/core/content_database.gd`
- `src/core/simulation_engine.gd`
- `src/infrastructure/save_repository.gd`
- `src/infrastructure/local_save_repository.gd`
- `data/content.json`
- `data/localization_en.json`
- `data/localization_zh_CN.json`
- `data/player_action_registry.json`
- `data/ui_state_registry.json`
- `data/gameplay_journey_registry.json`
- `tests/run_core_complete.sh`
- `project.godot`

At most one writing agent may own any of them. Prefer adding a new module behind
a stable adapter, then let the primary agent make the small integration edit.

### Project module lanes

Use these default ownership lanes when they fit the requested work. Paths marked
as future are target boundaries, not active ones; do not assign them until the
primary agent has landed the required contract and test fixture.

- Factory domain: `src/core/factory_grid_simulation.gd`, future
  `src/core/factory/**`, and focused factory-domain tests.
- Factory UI: future `src/ui/workspaces/factory/**`, factory view models, and
  factory UI tests. It consumes application snapshots and emits command intents;
  it does not mutate `Game.state` or call simulation mutators directly. Activate
  this lane only after a versioned Factory snapshot/command/event contract exists.
- Fleet UI: ship-registry/assembly components, fleet view models, fleet UI assets,
  and focused fleet UI tests. While roster coordination remains in `main.gd`, one
  writer exclusively owns the extraction and integration surface.
- UI platform: shared theme, shell, navigation, scenes, and registry contracts.
  This is a single-owner lane and is not implicit ownership for feature UI agents.
- Content: content source shards, content assembly/validation tools, and content
  contract tests. Until source shards exist, `data/content.json` remains a
  single-owner integration surface. Canonical IDs are stable cross-module APIs.
- Localization: both locale catalogs and localization audits. One writer owns all
  locale catalogs in a wave so their key sets remain synchronized.
- Logistics, Combat/Wreck, and Planner: use their existing isolated engine files
  and focused tests when the task does not require a shared State/Simulation edit.
- QA: new focused tests/fixtures, regression analysis, and independent reviews.
  QA agents do not change product behavior or the umbrella release runner unless
  explicitly reassigned as writers.
- Integration: application facade, save schema, asset ledger, top-level simulation
  order, cross-domain transactions, shared registries, and final release gates.

Save migration, asset ownership transfer, deterministic simulation ordering, and
Factory-to-Location/Logistics port transfer are single-owner integration work.
They may run alongside isolated UI or content work, but must not be divided among
concurrent writers.

### Handoff and integration

- A subagent reports concise results to the primary agent; it does not declare the
  overall task complete.
- The primary agent reviews every changed file and checks for overlapping edits,
  duplicated state authority, obsolete aggregate-industry paths, and missing tests.
- Merge or adapt contract changes before dependent implementations.
- Run focused tests after each module is integrated. On Unix-like systems, then
  run `./tests/run_core_complete.sh` for changes that can affect gameplay, state,
  content, persistence, or its covered core-domain gate. On Windows, invoke the
  equivalent Godot tests directly under the Windows rules below.
- The current script is not a complete UI or Golden Path release gate. If it does
  not cover the changed player path, add or run a focused
  replacement test and explicitly report that coverage gap.
- Final responses must distinguish subagent-reported results from checks actually
  rerun by the primary agent.

## Running Godot on Windows

- Before running a command that initializes `D:\Godot\godot.exe`, inspect the current permission profile. This applies to headless tests, scene runs, imports, editor starts, and exports; a plain `--version` check is exempt.
- If filesystem sandboxing is active and the command tool supports escalation, run Godot outside the sandbox by setting `sandbox_permissions` to `require_escalated`.
- Do not pause to ask the user before making that escalation request. This trusted project has a project-local allow rule for Godot commands, so matching commands should be approved automatically.
- This trusted project is configured with `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in `.codex/config.toml`. Execute all in-scope commands directly and do not pause to request permissions. Respect any read-only or target-specific limits stated in the user's task.
- If the permission profile is already unrestricted (`danger-full-access` or sandboxing disabled), run Godot directly and do not pass `sandbox_permissions`.
- Use the absolute project path `D:\Projects\standalone\core_gameplay_lab` with `--path`; do not rely on `--path .`.
- Invoke Godot directly and wait for its exit code. Do not launch automated Godot tests through `Start-Process`.
- If a restricted run prints `Failed to read the root certificate store`, stop it and rerun the same command outside the sandbox when policy permits. Do not repeatedly retry it inside the sandbox.

Godot 4.6.x can access-violate on Windows while starting or shutting down under restricted access to its AppData, certificate-store, or logging paths. The crash commonly reads address `0x58` and can appear after a test has already printed `PASS`, so it is an engine/sandbox failure rather than a test failure.
