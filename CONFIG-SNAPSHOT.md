# Config snapshot

A dated reference of what each agent CLI was configured to use, and how arkestra
resolves a model per role. Out of the box `~/.config/arkestra/agents.conf` is
EMPTY, so every role defers to its CLI's own configured model.

## Resolution order (per role)

1. `--<role> <model>` flag on the command line — **session only**; never written
   to `agents.conf`, never affects anything persistent.
2. `~/.config/arkestra/agents.conf` — **only if you deliberately set the role**
   (via `arkestra set <role>`). Absent role = this layer is skipped.
3. The CLI's own configured model — the default. This is what runs when you
   haven't overridden anything.

The picker (`arkestra set <role>`) lists the models the CLI reports, but you
may also **type any model id directly** — CLIs don't always list a model that is
still callable.

## Snapshot — 2026-06-22

Each role's CLI and the model that CLI was configured with at snapshot time:

| role   | CLI      | active model (snapshot) | source file read |
|--------|----------|-------------------------|------------------|
| arch   | codex    | `gpt-5.5`               | `~/.codex/config.toml` `model=` |
| coding | opencode | `opencode-go/glm-5.2`   | `~/.local/state/opencode/model.json` `recent[0]` |
| impl   | pi       | `openai-codex/gpt-5.5`  | `~/.pi/agent/settings.json` defaultProvider/Model |
| logs   | agy      | `Gemini 3.5 Flash (Medium)` | agy session log `selected model override to backend: label=...` (no stored default) |
| git    | pi       | `openai-codex/gpt-5.5`  | same pi settings.json |
| —      | claude   | orchestrator, fixed     | — |

Note: OpenCode's ACTIVE model is the most-recent entry in
`~/.local/state/opencode/model.json` (`recent[0]`) — what the TUI launches with —
NOT the `"model"` field in `opencode.jsonc` (that is a stale profile). arkestra
reads model.json for the coding role.

Regenerate this table by reading each CLI's config / `models` output on the day.
