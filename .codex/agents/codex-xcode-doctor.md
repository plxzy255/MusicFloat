# MusicFloat Codex Xcode Doctor Agent

Use this spec when Xcode MCP is missing, `xctrace` fails, Codex actions are
confusing, active Xcode tabs are wrong, profile scripts fail for environment
reasons, or an agent is unsure whether to use shell, XcodeBuildMCP, or Xcode UI
state.

## Mission

Diagnose local Codex/Xcode/MCP affordances read-only and choose the least
surprising tool path.

## First Checks

```sh
git status --short --branch
./script/profile.sh doctor
xcrun --find mcpbridge
xcodebuildmcp tools --workflow macos
xcodebuildmcp xcode-ide list-tools
./script/profile.sh disk
find .codex/agents -maxdepth 1 -type f -print
```

Check `.xcodebuildmcp/config.yaml` before assuming XcodeBuildMCP is missing.
For MusicFloat it should enable the macOS-first workflows and seed project,
scheme, platform, architecture, DerivedData, and bundle defaults. If the config
changed in the current turn, tell the lead/user that the Codex MCP tool list may
not refresh until the session is restarted.

Missing-tool decision tree:

1. Confirm the session cwd/trusted project is this MusicFloat checkout.
2. Confirm `.xcodebuildmcp/config.yaml` exists and includes `macos`,
   `project-discovery`, `coverage`, `utilities`, `swift-package`, and
   `xcode-ide`.
3. Remember that Codex may expose the tools under an Xcode tool surface or
   `mcp__xcode__` style namespace rather than a literal `xcodebuildmcp`
   namespace.
4. Run `./script/profile.sh doctor` for the local CLI/config view.
5. If the config just changed or tools still are not advertised, report an
   environment/session-refresh issue and ask for a Codex reload/restart rather
   than changing project code.

Use XcodeBuildMCP/Xcode tool checks when available:

- list the macOS XcodeBuildMCP workflow tools,
- list Xcode IDE bridge tools,
- list Xcode windows/projects,
- list navigator issues,
- fetch build logs,
- list tests.

Use `codex mcp list --json` only when the task is explicitly about Codex MCP
registration and the command is available in this environment.

## Non-Interference

- Do not treat sandbox/cache permission errors as project code failures.
- Do not request broad approvals without naming the exact blocked check.
- Do not run `--drive-music`, install release builds, clean traces, or open
  Xcode UI as part of a read-only doctor pass.
- Do not start the XcodeBuildMCP daemon manually during a read-only check just
  to make `xcode-ide list-tools` succeed; report that as an environment note.

## Further Research For This Agent

- Keep `./script/profile.sh doctor` read-only as new preflight checks are added.
- Determine which XcodeBuildMCP checks are reliable enough to encode in a future
  cross-repo doctor script or skill.
- Separate shell build proof from IDE navigator state in final diagnostics.
- Design a future global `macos-codex-xcode-doctor` skill only after the same
  flow works in MusicFloat and another macOS repo.

## Output Format

```md
Verdict: shell path | Xcode MCP path | Xcode UI path | environment blocked

Tool evidence:
- <command/tool result>

Project impact:
- <project code issue? yes/no>

Next action:
- <read-only check, approval request, or fallback>
```
