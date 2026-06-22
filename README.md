# arkestra

A team of CLI coding agents in tmux, orchestrated by Claude. You give the lead
one goal; it delegates scoped tasks to cheaper specialist agents, reviews their
work, and integrates. Invoked as `tools agents`.

```
┌─ orchestrator (Claude) ─┬─ arch    (codex)    ┐
│  delegates · reviews ·  │  coding  (opencode) │  each worker = a pane,
│  integrates             │  impl    (pi)       │  runs headless, signals
│                         │  logs    (agy)      │  done via a sentinel file
└─────────────────────────┴─ git     (pi)       ┘
```

## Quick start

```bash
tools agents                     # default roles: coding arch git
tools agents arch coding impl logs git   # all roles
tools agents --name api coding impl      # a named team (run several at once)
```

Pick the workspace, confirm the pre-flight table, attach. Then tell the
orchestrator what you want — it dispatches the right agents.

## How it works

- **Orchestrator = Claude**, always pane 0. It does NOT edit files; it
  **delegates** via `tools agents dispatch <role> "<task>"`, waits for each
  worker's sentinel, reviews the diff, and commits.
- **Workers run headless** with auto-approved permissions (never block on a
  prompt). On completion each writes `.agent-out/<role>.done` — line 1 = exit
  code, line 2 = a one-line summary. Full output is in `.agent-out/<role>.out`.
  A watchdog writes a failure sentinel (exit 124) if a worker hangs.
- **One shared workspace.** All agents work in the same tree (current checkout,
  another branch, or a fresh worktree — chosen at launch). Writers
  (coding/impl/git) run **one at a time** (the orchestrator sequences them);
  readers (arch/logs) run in parallel.
- **Context-frugal review.** The lead reads the one-line summary + `git diff
  --stat`, opening full output only when something looks wrong.

## Roles

| role   | default CLI | use case                      |
|--------|-------------|-------------------------------|
| arch   | codex       | architecture / second opinion |
| coding | opencode    | complex coding                |
| impl   | pi          | direct implementation         |
| logs   | agy         | log / code investigation      |
| git    | pi          | git operations                |

Any role can run on any harness (codex/opencode/pi/agy) — see below.

## Configuring models & harnesses

Per role you can set both the **harness** (which CLI) and the **model**.
Resolution, highest first:

1. `--<role> <model>` flag — this session only
2. `~/.config/arkestra/agents.conf` — your saved default
3. the CLI's own configured model — the fallback (empty conf = this)

```bash
tools agents set git                     # picker: harness, then model -> saved
tools agents coding --coding opencode/gpt-5.5   # one-session override
```

The picker lists the CLI's real models; you can also type any callable id.

## Layout & navigation

- **≤2 workers**: one window — orchestrator left, workers stacked right.
- **>2 workers**: orchestrator + first worker in window 0, the rest 2-per-window.
- `Option+Tab` next window · `Ctrl-b z` zoom a pane · click to focus (mouse on).

## Commands

```bash
tools agents [roles] [--<role> model] [--name <team>]   # launch
tools agents set <role>                  # set harness + model for a role
tools agents dispatch <role> "<task>"    # (the orchestrator uses this)
tools agents stop [--all] [--keep-out]   # stop a team (picks which if several)
tools agents install                     # check/install deps (macOS + Arch/Linux)
tools agents uninstall                   # remove arkestra's own files
```

## Requirements

`tmux`, `claude` (orchestrator), plus the agent CLIs for the roles you use
(`codex`, `opencode`, `pi`, `agy`), and `gum` for the nicest UI (falls back to
plain prompts without it). Run `tools agents install` to check.

Written to run on macOS (bash 3.2) and Arch/Linux. See `CONFIG-SNAPSHOT.md` for
how each CLI's active model is detected.
