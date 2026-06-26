<div align="center">

<img width="200" height="175" alt="Arkestra Logo" src="https://github.com/user-attachments/assets/13219b00-0001-4886-86af-b9716f64c9f5" />

# arkestra

**A team of CLI coding agents in tmux, orchestrated by Claude (or Codex).**

</div>

You give the lead one goal; it delegates scoped tasks to cheaper specialist
agents, reviews their work, and integrates. Invoked as `arkestra` (or the
short alias `ark`).

```
┌─ orchestrator ──────────┬─ arch    (codex)    ┐
│  delegates · reviews ·  │  coding  (opencode) │  each worker = a pane,
│  integrates             │  impl    (pi)       │  runs headless, signals
│                         │  logs    (agy)      │  done via a sentinel file
└─────────────────────────┴─ git     (pi)       ┘
```

How one task flows — the orchestrator never touches the work, only the result:

```
  orchestrator                          worker pane (headless)
        │
        │   dispatch <role> "task"           ┌────────────────────┐
        ├───────────────────────────────────▶│  runs the CLI      │
        │                                     │  streams → .out    │
        │   wait <role>                       │                    │
        │   (blocks — no polling,    ┌───◀────┤  writes .done      │
        │    no token burn)          │        │  (exit + summary)  │
        ▼                            │        └─────────┬──────────┘
   ┌──────────┐                      │                  │ silent?
   │  .done   │◀─────────────────────┘                  ▼
   └────┬─────┘                                  ┌──────────────┐
        │                                        │  watchdog    │
   exit 0 ──▶ read summary · diff --stat ·       │  stall 90s   │
        │     integrate · next task              │  cap 300s*   │
        │                                        └──────┬───────┘
   ≠0 / 124 ──▶ HALT · report · never DIY               │ hung → write 124
        ▲                                               │ + reclaim pane
        └───────────────────────────────────────────────┘  (SIGINT → respawn)
```

<sub>* cap is progress-aware: a worker still streaming output sails past it; it fires only once the worker is both past the cap and quiet.</sub>

<details>
<summary><b>Screenshots</b> — a 5-agent team across three windows</summary>

<br>

**Window 1** — orchestrator + arch
<img width="1728" alt="orchestrator and arch" src="https://github.com/user-attachments/assets/d6b70a9c-c18b-4b22-9321-84c66fb09cc8" />

**Window 2** — coding + impl
<img width="1728" alt="coding and impl" src="https://github.com/user-attachments/assets/1fece8e8-b351-4a76-ac79-18c3b6f91fc6" />

**Window 3** — logs + git
<img width="1725" alt="logs and git" src="https://github.com/user-attachments/assets/706fecc9-73c9-4e53-8c3e-9aa5ea544e0d" />

</details>


## Quick start

```bash
arkestra                         # default roles: coding arch git
arkestra arch coding impl logs git       # all roles
arkestra --name api coding impl          # a named team (run several at once)
ark coding git --start                   # short alias; launch and jump straight in
```

Pick the workspace, confirm the pre-flight table, attach (or pass `--start`
to attach automatically). Then tell the orchestrator what you want — it
dispatches the right agents.

> `arkestra` and `ark` are the same CLI — the command you type is what its help
> and the orchestrator's brief print back.

<img width="676" alt="workspace picker and pre-flight table" src="https://github.com/user-attachments/assets/c0e91c24-b78f-41d8-bfeb-f3de0d06e15c" />

## How it works

- **Orchestrator = Claude (default) or Codex**, always pane 0 — pick at launch
  or with `--orch <claude|codex>`. Both get the same brief + roster through
  their native instruction surface: Claude via `--append-system-prompt-file`,
  Codex via `-a never -s workspace-write` plus invocation-scoped
  `developer_instructions`. Codex is not seeded with a fake first prompt; the
  pane waits for your actual goal. The orchestrator does NOT edit files; it
  **delegates** via `arkestra dispatch <role> "<task>"`, waits for each worker's
  sentinel, reviews the diff, and commits.
- **Workers run headless** with auto-approved permissions (never block on a
  prompt), under a pseudo-TTY so each CLI keeps its **native colors/formatting**
  live in the pane (easy to follow the reasoning). On completion each writes
  `.agent-out/<role>.done` — line 1 = exit code, line 2 = a one-line summary.
  Full output is in `.agent-out/<role>.out` (de-ANSI'd, clean for tooling).
  A watchdog writes a failure sentinel (exit 124) if a worker hangs — detected
  by an output **stall** (`.out` stops growing for `ARKESTRA_STALL`s, default
  90). The `ARKESTRA_TIMEOUT` cap (default 300s) is a *progress-aware* backstop:
  past the cap it fires only if the worker has *also* gone quiet, so a healthy
  worker that keeps streaming output is never killed mid-task — only one that's
  blown the cap **and** fallen silent (the real "wedged" shape). Set
  `ARKESTRA_HARD_STRICT=1` to restore an absolute wall-clock guillotine. On a
  hang it also reclaims the pane (SIGINT, then respawn if needed) so the role is
  ready for the next dispatch.
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

Any role can run on any harness (codex/opencode/pi/agy/reasonix) — see below.

## Configuring models & harnesses

Per role you can set both the **harness** (which CLI) and the **model**.
Resolution, highest first:

1. `--<role> <model>` flag — this session only
2. `~/.config/arkestra/agents.conf` — your saved default
3. the CLI's own configured model — the fallback (empty conf = this)

```bash
arkestra set git                     # picker: harness, then model -> saved
arkestra coding --coding opencode/gpt-5.5   # one-session override
```

The picker lists the CLI's real models; you can also type any callable id.

**Change a model mid-session** without losing orchestrator context. Workers are
stateless between dispatches (each runs headless, then exits), so swapping a
worker's model only needs to take effect on the *next* dispatch:

```bash
arkestra model coding opencode/claude-opus-4-8   # keep harness, new model
arkestra model git pi pi/mimo-v2.5-free          # switch harness + model
```

The orchestrator (pane 0) is untouched — its conversation survives.
`set` saves a default for future launches; `model` retargets the running team.

## Layout & navigation

- **≤2 workers**: one window — orchestrator left, workers stacked right.
- **>2 workers**: orchestrator + first worker in window 0, the rest 2-per-window.
- `Option+Tab` next window · `Ctrl-b z` zoom a pane · click to focus (mouse on).
- Detached? `arkestra sessions` lists running teams and attaches to one
  (switches client if you're already inside tmux).

## Commands

```bash
arkestra [roles] [--<role> model] [--name <team>] [--start]   # launch
arkestra sessions [name]             # list running teams and attach to one
arkestra set <role>                  # set harness + model for a role (saved)
arkestra model <role> [harness] <model>   # hot-swap a LIVE worker's model
arkestra dispatch <role> "<task>"    # (the orchestrator uses this)
arkestra wait <role>                 # (orchestrator) block on a worker's result
arkestra stop [--all] [--keep-out]   # stop a team (picks which if several)
arkestra install                     # check/install deps (macOS + Arch/Linux)
arkestra uninstall                   # remove arkestra's own files
```

## Requirements

`tmux`, one orchestrator CLI (`claude` or `codex`), plus the agent CLIs for the
roles you use (`codex`, `opencode`, `pi`, `agy`, `reasonix`), and `gum` for the
nicest UI (falls back to plain prompts without it). Run `arkestra install`
to check.

Written to run on macOS (bash 3.2) and Arch/Linux. See `CONFIG-SNAPSHOT.md` for
how each CLI's active model is detected.

## CLIs used

arkestra orchestrates these external CLIs — install the ones you need via their
own docs (`arkestra install` checks what's present):

| CLI        | role               | website                                              |
|------------|--------------------|------------------------------------------------------|
| `claude`   | orchestrator       | https://docs.claude.com/claude-code                  |
| `codex`    | arch / orchestrator | https://github.com/openai/codex                      |
| `opencode` | coding (default)   | https://opencode.ai                                  |
| `pi`       | impl/git (default) | https://pi.dev                                       |
| `agy`      | logs (default)     | https://antigravity.google                           |
| `reasonix` | any role           | https://github.com/esengine/deepseek-reasonix        |
| `tmux`     | pane multiplexer   | https://github.com/tmux/tmux                         |
| `gum`      | TUI (optional)     | https://github.com/charmbracelet/gum                 |
