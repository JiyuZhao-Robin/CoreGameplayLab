# Agent instructions

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
