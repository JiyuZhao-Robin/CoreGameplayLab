# Parallel Agent Playbook

This playbook defines how one primary agent coordinates parallel Codex work in
CoreGameplayLab. The goal is high throughput with one integration authority, not
maximum simultaneous edits.

## Operating model

```text
User intent
    ↓
Primary agent: scope, contracts, ownership, integration, final verification
    ├── Project explorer: read-only execution-path and boundary analysis
    ├── Module worker(s): one or two mutually disjoint write surfaces
    └── Integration reviewer: read-only correctness and test review
```

The primary agent is accountable for the complete outcome. Subagents provide
bounded results and never replace final integration judgment. Select at most
three of the displayed subagent roles in one wave; the diagram describes role
choices, not four simultaneous children.

Project custom-agent profiles are loaded by new sessions and only when the
client supports selecting them. Parent runtime permission overrides may also
supersede a profile sandbox. Treat profile sandboxes as defense in depth, never
as path isolation: root instructions, task packets, and the ownership map remain
the enforceable collaboration contract. Restart existing sessions after changing
these files.

## Choose the collaboration shape

Use one of these shapes before work begins:

1. **Parallel discovery**: two or three read-only agents inspect different risks;
   the primary agent synthesizes and implements.
2. **One writer plus reviewers**: one agent owns all implementation files while
   other agents inspect tests, behavior, or documentation. Use this for changes
   centered on a hotspot file.
3. **Disjoint writers**: two or three agents edit mutually exclusive directories
   behind an already agreed contract. Use this for new components, content shards,
   independent tests, or isolated domain modules.
4. **Separate worktree chats**: when the user has already authorized the required
   Git operations, each substantial feature has a committed baseline, its own
   worktree and branch, focused tests, and a later integration review. Otherwise
   use one shared-checkout writer plus read-only reviewers.

Do not split a deterministic transaction, schema migration, asset transfer, or
top-level simulation step across concurrent writers.

## Task packet template

Copy this into every writing-agent assignment:

```text
Objective:
<one observable outcome>

Owned paths:
- <files/directories this agent may edit>

Pre-existing dirty state:
- <dirty owned paths and how this task may modify them, or "none">

Forbidden paths:
- <shared/hotspot files this agent must not edit>

Stable contracts:
- <method names, event shapes, IDs, save fields, node names>

Done when:
- <behavioral acceptance criteria>
- <focused tests pass>

Verification:
- <exact commands>
- <repository paths the commands may write>

Handoff:
- changed files
- test commands and results
- assumptions
- interface requests or remaining risks

If work requires an edit outside Owned paths, do not make it. Return an interface
request to the primary agent.
```

An exploration or review assignment omits `Owned paths` and is therefore
read-only. It must not run Godot, import/export, generators, or other commands
that may write repository caches or artifacts; the primary agent runs those
checks serially unless a separate worktree and isolated output root are assigned.

## Current rewrite example (temporary)

This section applies only while `docs/implementation-status.md` still marks the
Factory Canvas or its Golden Path as incomplete. Remove or rewrite it when both
are complete; the collaboration protocol above remains valid afterward.

### Foundation wave

The primary agent establishes contracts and the verified baseline:

- reconcile current documentation with Save Schema and the live runtime;
- define Factory workspace snapshots, commands, events, and reason codes;
- define which legacy aggregate-industry surfaces are removal-only;
- split test entry points into focused domain, contract, UI, and journey gates;
- finish existing Ship Registry work, or create a checkpoint only when the user
  has authorized that Git operation, before opening overlapping branches.

### Parallel implementation wave

- **Fleet UI writer**: extract roster presentation and interaction from
  `src/ui/main.gd`. This writer exclusively owns `main.gd` for the wave.
- **Factory Canvas writer**: develop new files under
  `src/ui/workspaces/factory/**` and `src/ui/view_models/factory/**` against
  snapshot fixtures; integration mounting remains with the primary agent. This
  lane activates only after the primary agent lands the snapshot/command/event
  contract and fixtures.
- **Content writer**: introduce deterministic content source shards and assembly
  validation without changing simulation behavior.
- **QA/review agents**: remain read-only or own only new focused test files.

### Integration wave

The primary agent integrates in dependency order:

1. contracts and adapters;
2. content assembly and validation;
3. isolated domain modules;
4. UI workspace mounting;
5. focused tests;
6. the release gate and a diff review.

## Worktree protocol

Create manual worktrees only when the user requested the Git operation or the
task explicitly includes repository setup. Start from a committed, tested
baseline. Never discard or silently copy unrelated dirty changes. Use a separate
branch for every retained worktree.

Example naming:

```text
ai/integration
ai/fleet-ui
ai/factory-canvas
ai/factory-content
ai/qa
```

Codex-managed worktree chats may begin detached. Create a branch in that worktree
before retaining or sharing its commits. Do not check out the same branch in two
worktrees.

Every worktree must contain the tracked project `.codex/config.toml`, root
`AGENTS.md`, and this playbook. Existing sessions load agent instructions at
startup, so restart or open a new session after instruction changes.

## Verification commands

In a shared checkout, the primary agent runs these commands serially because
Godot can update `.godot` and several UI suites write fixed artifacts. Separate
worktrees may run them concurrently only with isolated logs and artifact roots.

Canonical Unix-like commands from the repository root:

```bash
# Current core-domain umbrella; this is not a complete UI/Golden Path gate.
./tests/run_core_complete.sh

# Factory domain.
godot --headless --path . --log-file /tmp/helios-factory-grid.log \
  --script res://tests/factory_grid_simulation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-assets.log \
  --script res://tests/asset_conservation_test.gd -- --no-persistence

# Content contracts.
python3 -m json.tool data/content.json >/dev/null
godot --headless --path . --log-file /tmp/helios-content.log \
  --script res://tests/content_planner_contract_test.gd -- --no-persistence

# Fleet domain and UI integrity.
godot --headless --path . --log-file /tmp/helios-formations.log \
  --script res://tests/operational_formation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-domain.log \
  res://tests/ui_domain_integrity_test.tscn -- --no-persistence

# Save/migration and state ownership.
godot --headless --path . --log-file /tmp/helios-core-integrity.log \
  --script res://tests/core_integrity_test.gd -- --no-persistence
```

On Windows, follow the root `AGENTS.md`: invoke `D:\Godot\godot.exe` directly,
use `--path D:\Projects\standalone\core_gameplay_lab`, and do not run the zsh
umbrella script. The primary agent translates the same targets into direct Godot
commands and waits for each exit code.

STEP 09-12 Ship Registry tests are not portable to another worktree until their
currently untracked files enter an authorized committed baseline.

## Verification matrix

| Change type | Minimum verification |
| --- | --- |
| Read-only analysis | Evidence with file/symbol references |
| UI component | Its focused scene test and the UI-domain command above |
| Factory domain | Both Factory-domain commands above |
| Content | Both Content-contract commands above |
| Fleet | Its focused scene test plus both Fleet/UI commands above |
| State or migration | Core-integrity and asset-conservation commands above |
| Cross-domain integration | Focused commands, then the current core-domain umbrella |

The current umbrella runs only JSON validation and six domain scripts. It does
not run the UI suites, Player Action/Journey registries, legacy headless suite,
or Golden Path. Every affected change must report the focused evidence used for
those gaps; never call the current umbrella a complete release certification.

## Handoff format

Every subagent returns:

```text
Status: complete | blocked | review findings
Changed: <paths, or none>
Verified: <commands and outcomes>
Contracts: <added/changed/unchanged>
Risks: <remaining risks>
Needs from integrator: <adapter or decision, if any>
```

The primary agent must independently inspect the diff and rerun the checks it
claims in the final response. A subagent's successful test report is supporting
evidence, not the final release decision.

## Ready-to-use orchestration prompt

```text
Use up to three subagents under the repository multi-agent playbook. Prefer the
project_explorer, module_worker, and integration_reviewer roles when selectable;
otherwise reproduce their constraints in each task packet.

First record the pre-wave status/diff and a path ownership map, including dirty
paths and verification side effects. Divide the request into genuinely independent
tracks. Give every writing agent a complete task packet with non-overlapping owned
paths; keep discovery and review agents read-only. Do not release or reassign
ownership until a handoff arrives or interruption is confirmed. The primary agent
owns shared contracts, integration edits, final diff review, and final verification.
Wait for all relevant handoffs, resolve conflicts, run focused tests and the
applicable gates, then report what the primary agent actually verified.
```
