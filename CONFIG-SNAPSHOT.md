# Config snapshot

A dated reference of what each agent CLI was configured to use, and how arkestra
resolves a model per role. Out of the box `~/.config/arkestra/agents.conf` is
EMPTY, so every role defers to its CLI's own configured model.

## Resolution order (per role)

1. `--<role> <model>` flag on the command line — **session only**; never written
   to `agents.conf`, never affects anything persistent.
2. `~/.config/arkestra/agents.conf` — **only if you deliberately set the role**
   (via `tools agents set <role>`). Absent role = this layer is skipped.
3. The CLI's own configured model — the default. This is what runs when you
   haven't overridden anything.

The picker (`tools agents set <role>`) lists the models the CLI reports, but you
may also **type any model id directly** — CLIs don't always list a model that is
still callable.

## Snapshot — 2026-06-22

Each role's CLI and the model that CLI was configured with at snapshot time:

| role   | CLI      | CLI's configured model (snapshot)     |
|--------|----------|---------------------------------------|
| arch   | codex    | `gpt-5.5`                             |
| coding | opencode | `ollama/qwen3:4b-instruct`            |
| impl   | pi       | `openai-codex/gpt-5.3-codex-spark`    |
| logs   | gemini   | gemini CLI default                    |
| git    | pi       | (same pi default as impl)             |
| —      | claude   | orchestrator, fixed                   |

Note: OpenCode's *active* top-level `model` was `ollama/qwen3:4b-instruct` at
snapshot — other models (glm, etc.) existed under its `models` profiles block but
were not the active default. To make a role use one of those, either change the
CLI's own config or set it in arkestra via `tools agents set <role>`.

Regenerate this table by reading each CLI's config / `models` output on the day.
