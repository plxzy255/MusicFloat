# MusicFloat Codex Workflow Router

Use this spec when a task is broad, ambiguous, asks for agents/skills/Codex
workflow design, or may need multiple specialist passes.

## Mission

Route Codex work without forcing delegation or bloating context. The lead agent
keeps ownership of the final answer and working tree. Subagents are bounded
investigators, not background processes competing for the same app session.

## Precedence

System and developer instructions override this spec. `AGENTS.md` repo rules
override specialist preferences when they conflict.

Shared workflow rules, non-interference policy, and evidence requirements live
in `AGENTS.md`. This spec should route work and record delegation decisions,
not duplicate every specialist's operating manual.

## Official Guidance Applied

- Use `AGENTS.md` for recurring repo rules, over-reading prevention, and
  review-feedback patterns.
- Use handoffs when there is more than one agent and ownership needs to be
  explicit.
- Use guardrails or human approval before risky steps.
- Turn repeatable workflows into skills only after the workflow has stable
  inputs, outputs, and a few concrete use cases.
- Use traces or compact reports to debug runs before expanding into evaluation
  loops.

Relevant docs:

- https://developers.openai.com/codex/concepts/customization#when-to-update-agentsmd
- https://developers.openai.com/codex/learn/best-practices#turn-repeatable-work-into-skills
- https://developers.openai.com/api/docs/guides/agents#choose-your-starting-point
- https://developers.openai.com/api/docs/guides/agents/integrations-observability#tracing

## First Checks

```sh
git status --short --branch
find .codex/agents -maxdepth 1 -type f -print
sed -n '1,240p' AGENTS.md
sed -n '1,220p' reports/report-index.md
```

If `reports/report-index.md` does not exist, read only the report named by the
user or the one routed from `AGENTS.md`.

## Quick Route Table

| Task type | Route | First files or commands | Forbidden overlap |
| --- | --- | --- | --- |
| Simple docs, single-file fix, or narrow explanation | Lead-only | `git status --short --branch`, targeted `rg`/`sed` | Delegation that needs the same write scope |
| Agent workflow, Codex surface, or broad repo report | Lead-only unless user requested agents | `AGENTS.md`, this router, `reports/report-index.md` | Bulk-reading all reports or derived artifacts |
| Build, test, warning, or CI failure | Lead-only unless separate read-only triage is useful | `.codex/agents/build-test-triage.md`, failing log, focused test command | Parallel build/test against `.codex/DerivedData` |
| Performance, memory, power, or regression claim | Delegate only bounded sidecar research or isolated profiling | `.codex/PROFILING.md`, `.codex/agents/performance-profiler.md`, `./script/profile.sh report` | Mixed-mode comparisons, shared trace dirs, shared ledger writes |
| Live Apple Music lyrics behavior | Lead-only for the running app session | `.codex/agents/live-lyrics-forensics.md`, targeted `cv.MusicFloat` logs | Any parallel app launch, live profile, or Music.app driver |
| Privacy, entitlements, cache, or provider boundary audit | Delegate read-only review if independent | matching specialist spec, targeted source/tests | Release install, permission changes, cache cleanup |
| Release identity, install, or notarization-adjacent checks | Lead-only unless read-only artifact review is separate | `.codex/agents/release-identity-doctor.md`, `script/release_self.sh --memory` only when asked/approved | Install/release commands overlapping verify/profile |
| Final handoff verification | Lead-only | `.codex/agents/musicfloat-agent-check.md`, `./script/agent_verify.sh` | Any concurrent build/test/profile/app launch in this checkout |

## Delegation Rules

When this runtime exposes multi-agent tools, spawn subagents only if the user
explicitly asked for subagents, delegation, or parallel agent work. Otherwise,
use these repo-local specs as local routing guidance and keep the work in the
lead agent.

Before spawning, decide the immediate task the lead agent will continue doing
locally. Delegate only sidecar work that can run in parallel without blocking
that immediate path.

Delegate when:

- the task spans independent risk zones such as performance plus privacy,
  release identity plus live lyrics, or parser correctness plus caching;
- a specialist can answer from read-only diagnostics or an isolated worktree;
- the output can be a compact verdict, evidence list, and next action.

Keep the lead agent only when:

- the request is a small edit or narrow explanation;
- the next command must own the only MusicFloat, Music.app, Xcode, or
  Instruments session;
- another agent would need to write the same files;
- reading the specialist spec would cost more context than the task itself.

Use explorer-style agents for specific read-only codebase questions. Use
worker-style agents only when their write scope is disjoint and they are told not
to revert or overwrite others' changes. Close subagents once their result has
been integrated.

## Non-Interference

- Do not run build, test, profile, release, or app-launch commands in parallel
  against the same checkout, `.codex/DerivedData`, `.codex/traces`,
  `reports/performance-runs.jsonl`, or running `cv.MusicFloat` instance.
- Treat `build_and_run.sh --verify`, live profiling, release memory sampling,
  and release install as session-owning commands.
- Use isolated `RUN_LEDGER`, `TRACE_DIR`, and `DERIVED_DATA_DIR` for exploratory
  measurements.
- Do not clean traces, install bundles, drive Music.app playback, or kill
  processes unless the user asked or approved.
- Use approval when supported by runtime policy; otherwise require explicit user
  instruction in prompt history before forbidden side effects.

## Subagent Handoff Template

Every delegation must include this routing record:

```md
Routing record:
- Lead task continuing locally: <what the lead will keep doing>
- Delegated question: <one bounded question>
- Allowed paths/commands: <read/write paths and commands>
- Forbidden side effects: <commands or app/session changes not allowed>
- Expected output shape: <verdict/evidence/risks/next action>
- Write/no-write scope: <no writes or exact disjoint write scope>
- Report/tracker paths: <paths to update, or none>
- Precedence: System and developer instructions override this spec; AGENTS.md
  repo rules override specialist preferences when they conflict.

Context:
- <paths already inspected>
- <current branch/dirty state>

Output:
- Verdict: pass | fail | partial | inconclusive
- Evidence:
- Recommended next research:
- Report update needed: yes/no
```

## Further Research For This Agent

- Check whether repeated MusicFloat tasks should graduate from `.codex/agents`
  into `.agents/skills` after two or three successful reuses.
- Keep `script/agent_verify.sh` lightweight: add only concise checks or
  reminders that match stable manual verification.
- Audit or change `.codex/environments/environment.toml` only through
  `./script/generate_codex_environment.sh` because it is marked autogenerated.

## Output Format

```md
Routing decision: lead-only | delegate

Specialist specs:
- <spec path and why>

Shared guardrails:
- <side-effect boundaries>

Next research prompts:
- <bounded prompt for each subagent>
```
