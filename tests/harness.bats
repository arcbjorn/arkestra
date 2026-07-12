#!/usr/bin/env bats
#
# Tests for arkestra's per-harness plumbing (default_for / list_models_for /
# valid_for / worker_cmd) across every supported harness.
#
# arkestra.sh is sourced, not executed (a BASH_SOURCE guard keeps main from
# running), so its functions can be called directly. Each test stubs the CLIs
# and config files it needs onto an isolated PATH / HOME, so the suite is
# hermetic: nothing needs to be installed or configured on the machine.

load helpers

setup() { arkestra_setup; }
teardown() { arkestra_teardown; }

# ---------------------------------------------------------------------------
# harness registry
# ---------------------------------------------------------------------------

@test "all expected harnesses are recognized" {
  source_arkestra
  for h in codex opencode pi agy reasonix grok; do
    run is_harness "$h"
    [ "$status" -eq 0 ] || { echo "is_harness $h failed"; return 1; }
  done
}

@test "claude is not a worker harness (it orchestrates)" {
  source_arkestra
  run is_harness claude
  [ "$status" -ne 0 ]
}

@test "an unknown harness is rejected" {
  source_arkestra
  run is_harness nope
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# codex
# ---------------------------------------------------------------------------

@test "codex default model comes from ~/.codex/config.toml" {
  mkdir -p "${FAKE_HOME}/.codex"
  printf 'model = "gpt-5.5-codex"\n' > "${FAKE_HOME}/.codex/config.toml"
  source_arkestra
  run default_for codex
  [ "$output" = "gpt-5.5-codex" ]
}

@test "codex model list is the openai-codex ids from pi" {
  stub_cli pi 'echo "provider model extra"; echo "openai-codex gpt-5.5-codex x"; echo "anthropic claude-opus x"'
  source_arkestra
  run list_models_for codex
  [ "$output" = "gpt-5.5-codex" ]
}

@test "codex worker_cmd is sandboxed workspace-write exec" {
  source_arkestra
  run worker_cmd codex gpt-5.5-codex "do it"
  [ "$output" = "codex exec -s workspace-write -m 'gpt-5.5-codex' 'do it'" ]
}

# ---------------------------------------------------------------------------
# opencode
# ---------------------------------------------------------------------------

@test "opencode model list and validation use 'opencode models'" {
  stub_cli opencode '[ "$1" = "models" ] && { echo "anthropic/claude-opus-4-8"; echo "openai/gpt-5.5"; }'
  source_arkestra
  run list_models_for opencode
  [ "${lines[0]}" = "anthropic/claude-opus-4-8" ]
  [ "${lines[1]}" = "openai/gpt-5.5" ]
  run valid_for opencode "openai/gpt-5.5"
  [ "$status" -eq 0 ]
  run valid_for opencode "openai/nope"
  [ "$status" -ne 0 ]
}

@test "opencode default model comes from jsonc when no state file" {
  mkdir -p "${FAKE_HOME}/.config/opencode"
  printf '{ "model": "anthropic/claude-opus-4-8" }\n' \
    > "${FAKE_HOME}/.config/opencode/opencode.jsonc"
  source_arkestra
  run default_for opencode
  [ "$output" = "anthropic/claude-opus-4-8" ]
}

@test "opencode worker_cmd skips permissions" {
  source_arkestra
  run worker_cmd opencode "openai/gpt-5.5" "task"
  [ "$output" = "opencode run --dangerously-skip-permissions -m 'openai/gpt-5.5' 'task'" ]
}

# ---------------------------------------------------------------------------
# pi
# ---------------------------------------------------------------------------

@test "pi model list is provider/model pairs from --list-models" {
  # First line is a header (skipped by the code), then provider+model rows.
  stub_cli pi 'echo "PROVIDER MODEL"; echo "anthropic claude-opus-4-8"; echo "openai gpt-5.5"'
  source_arkestra
  run list_models_for pi
  [ "${lines[0]}" = "anthropic/claude-opus-4-8" ]
  [ "${lines[1]}" = "openai/gpt-5.5" ]
}

@test "pi validation matches the bare model id" {
  stub_cli pi 'echo "PROVIDER MODEL"; echo "anthropic claude-opus-4-8"'
  source_arkestra
  run valid_for pi "anthropic/claude-opus-4-8"
  [ "$status" -eq 0 ]
  run valid_for pi "anthropic/ghost-model"
  [ "$status" -ne 0 ]
}

@test "pi default model comes from settings.json" {
  mkdir -p "${FAKE_HOME}/.pi/agent"
  printf '{ "defaultProvider": "anthropic", "defaultModel": "claude-opus-4-8" }\n' \
    > "${FAKE_HOME}/.pi/agent/settings.json"
  source_arkestra
  run default_for pi
  [ "$output" = "anthropic/claude-opus-4-8" ]
}

@test "pi worker_cmd approves and passes the model" {
  source_arkestra
  run worker_cmd pi "anthropic/claude-opus-4-8" "task"
  [ "$output" = "pi --approve --model 'anthropic/claude-opus-4-8' -p 'task'" ]
}

# ---------------------------------------------------------------------------
# agy
# ---------------------------------------------------------------------------

@test "agy model list is 'agy models'" {
  stub_cli agy '[ "$1" = "models" ] && { echo "gemini-3-pro"; echo "gemini-3-flash"; }'
  source_arkestra
  run list_models_for agy
  [ "${lines[0]}" = "gemini-3-pro" ]
  [ "${lines[1]}" = "gemini-3-flash" ]
}

@test "agy validation only requires the CLI to exist" {
  stub_cli agy 'true'
  source_arkestra
  run valid_for agy "any-model"
  [ "$status" -eq 0 ]
}

@test "agy default falls back when no log exists" {
  source_arkestra
  run default_for agy
  [ "$output" = "agy default" ]
}

@test "agy worker_cmd skips permissions" {
  source_arkestra
  run worker_cmd agy "gemini-3-pro" "task"
  [ "$output" = "agy --dangerously-skip-permissions --model 'gemini-3-pro' -p 'task'" ]
}

# ---------------------------------------------------------------------------
# reasonix
# ---------------------------------------------------------------------------

@test "reasonix model list and default come from doctor --json" {
  # Real `doctor --json` is pretty-printed: one "name" per line (the extraction
  # regex is greedy, so it relies on that).
  stub_cli reasonix '[ "$1" = "doctor" ] && cat <<OUT
{
  "default_model": "deepseek-flash",
  "models": [
    { "name": "deepseek-flash" },
    { "name": "deepseek-pro" }
  ]
}
OUT'
  source_arkestra
  run list_models_for reasonix
  [ "${lines[0]}" = "deepseek-flash" ]
  [ "${lines[1]}" = "deepseek-pro" ]
  run default_for reasonix
  [ "$output" = "deepseek-flash" ]
}

@test "reasonix validation matches a provider name" {
  stub_cli reasonix '[ "$1" = "doctor" ] && cat <<OUT
{
  "models": [
    { "name": "deepseek-flash" },
    { "name": "deepseek-pro" }
  ]
}
OUT'
  source_arkestra
  run valid_for reasonix "deepseek-flash"
  [ "$status" -eq 0 ]
  run valid_for reasonix "deepseek-ghost"
  [ "$status" -ne 0 ]
}

@test "reasonix worker_cmd uses 'run' with no global flags" {
  source_arkestra
  run worker_cmd reasonix "deepseek-flash" "task"
  [ "$output" = "reasonix run --model 'deepseek-flash' 'task'" ]
}

# ---------------------------------------------------------------------------
# grok
# ---------------------------------------------------------------------------

# grok's `models` output shape: "Default model: <id>" + "* <id> (default)" / "- <id>".
grok_models_stub() {
  stub_cli grok '[ "$1" = "models" ] && cat <<OUT
You are not authenticated.

Default model: grok-4.5

Available models:
  * grok-4.5 (default)
  - grok-composer-2.5-fast
OUT'
}

@test "grok default model comes from 'grok models'" {
  grok_models_stub
  source_arkestra
  run default_for grok
  [ "$output" = "grok-4.5" ]
}

@test "grok model list parses both bullet styles" {
  grok_models_stub
  source_arkestra
  run list_models_for grok
  [ "${lines[0]}" = "grok-4.5" ]
  [ "${lines[1]}" = "grok-composer-2.5-fast" ]
}

@test "grok accepts a listed model and rejects others" {
  grok_models_stub
  source_arkestra
  run valid_for grok grok-4.5
  [ "$status" -eq 0 ]
  run valid_for grok bogus-model
  [ "$status" -ne 0 ]
  run valid_for grok ""
  [ "$status" -ne 0 ]
}

@test "grok worker_cmd is single-turn headless with auto approval" {
  source_arkestra
  run worker_cmd grok grok-4.5 "fix the parser bug"
  [ "$output" = "grok -p 'fix the parser bug' -m 'grok-4.5' --permission-mode auto" ]
}

# ---------------------------------------------------------------------------
# cross-cutting
# ---------------------------------------------------------------------------

@test "worker_cmd safely quotes a task containing a single quote" {
  source_arkestra
  run worker_cmd grok grok-4.5 "don't break"
  [ "$output" = "grok -p 'don'\''t break' -m 'grok-4.5' --permission-mode auto" ]
}

@test "role defaults map to the expected harnesses" {
  source_arkestra
  [ "$(default_harness arch)" = "codex" ]
  [ "$(default_harness coding)" = "opencode" ]
  [ "$(default_harness impl)" = "pi" ]
  [ "$(default_harness logs)" = "agy" ]
  [ "$(default_harness git)" = "pi" ]
}

@test "grok is not wired as a default for any role" {
  source_arkestra
  for role in arch coding impl logs git; do
    run default_harness "$role"
    [ "$output" != "grok" ]
  done
}
