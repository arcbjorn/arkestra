#!/usr/bin/env bats
#
# Tests for arkestra's per-harness plumbing, using grok as the subject.
# The script is sourced (not executed) thanks to the BASH_SOURCE guard in
# arkestra.sh, so we can call its functions directly.
#
# `grok` is stubbed on PATH with canned `grok models` output, so these tests
# are hermetic: they do not require grok to be installed or authenticated.

setup() {
  ARKESTRA="${BATS_TEST_DIRNAME}/../arkestra.sh"

  # Stub `grok` with the real CLI's `models` output shape:
  #   "Default model: <id>" plus "* <id> (default)" / "- <id>" bullets.
  STUB_DIR="$(mktemp -d)"
  cat > "${STUB_DIR}/grok" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "models" ]; then
  cat <<'OUT'
You are not authenticated.

Default model: grok-4.5

Available models:
  * grok-4.5 (default)
  - grok-composer-2.5-fast
OUT
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_DIR}/grok"
  PATH="${STUB_DIR}:${PATH}"

  # Source the functions under test (guard prevents main from running).
  source "$ARKESTRA"
}

teardown() {
  rm -rf "$STUB_DIR"
}

@test "grok is a recognized harness" {
  run is_harness grok
  [ "$status" -eq 0 ]
}

@test "grok default model comes from 'grok models'" {
  run default_for grok
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.5" ]
}

@test "grok model list parses both bullet styles" {
  run list_models_for grok
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "grok-4.5" ]
  [ "${lines[1]}" = "grok-composer-2.5-fast" ]
}

@test "grok accepts a listed model" {
  run valid_for grok grok-4.5
  [ "$status" -eq 0 ]
}

@test "grok rejects an unlisted model" {
  run valid_for grok bogus-model
  [ "$status" -ne 0 ]
}

@test "grok rejects an empty model" {
  run valid_for grok ""
  [ "$status" -ne 0 ]
}

@test "grok worker_cmd is single-turn headless with auto approval" {
  run worker_cmd grok grok-4.5 "fix the parser bug"
  [ "$status" -eq 0 ]
  [ "$output" = "grok -p 'fix the parser bug' -m 'grok-4.5' --permission-mode auto" ]
}

@test "grok worker_cmd safely quotes a task containing a single quote" {
  run worker_cmd grok grok-4.5 "don't break"
  [ "$status" -eq 0 ]
  [ "$output" = "grok -p 'don'\''t break' -m 'grok-4.5' --permission-mode auto" ]
}

@test "grok is not wired as a default for any role" {
  for role in arch coding impl logs git; do
    run default_harness "$role"
    [ "$output" != "grok" ]
  done
}
