# arkestra

Launch a tmux structure of CLI coding agents orchestrated by Claude,
coordinated via file sentinels. Invoked as `tools agents`.

- **orchestrator** = Claude, always pane 0 (left half of window 0)
- **workers** run headless: narration + diffs stream to the pane, the process
  exits and writes `.agent-out/<role>.done` with its exit code. Zoom any pane
  with `Ctrl-b z`; next window with `Ctrl-b n`.
- **one shared workspace** (not a worktree per role). Picked at launch: default
  is the current checkout; you may switch to another local branch or spin up a
  fresh worktree off a base. All workers operate in that one tree. Writers go
  sequential (the orchestrator sequences them — two editors on one tree
  collide); read-only roles (arch, logs) run in parallel. The git role commits
  in the shared workspace; merge to the default branch is the orchestrator's job.
- **pre-flight probe** resolves each role's model (resolution order:
  `--<role>` flag > `~/.config/arkestra/agents.conf` > the CLI's own default),
  validates it against that CLI's real model list, and blocks with suggested
  fixes before launching anything.

## Persistent per-role model defaults

Set once, used on every launch (no re-typing). The picker lists the real models
from that role's CLI — nothing invented:

```bash
tools agents set coding     # pick from opencode's models -> ~/.config/arkestra/agents.conf
tools agents set impl       # pick from pi's models
```

## Roles (fixed priority; give any subset, unused are skipped)

| role   | CLI      | use case                       |
|--------|----------|--------------------------------|
| arch   | codex    | architecture / second opinion  |
| coding | opencode | complex coding                 |
| impl   | pi       | direct implementation          |
| logs   | agy      | deep log / investigation       |
| git    | pi       | git operations (small/fast)    |

## Usage

```bash
tools agents                                  # default set: coding arch git
tools agents coding arch                       # pick roles
tools agents coding --coding opencode/claude-opus-4-8   # override a model
```

Layout: `<=2` workers share one window (orch left, workers stacked right);
`>2` puts orch+worker1 in window 0 and the rest 2-per-window.

bash 3.2 safe (no associative arrays, no `\s` in sed, no `timeout`).
