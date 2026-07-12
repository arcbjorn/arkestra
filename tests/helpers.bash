#!/usr/bin/env bash
#
# Shared test helpers. Each test creates a throwaway BIN_DIR (fake CLIs) and a
# throwaway HOME (fake config files), so arkestra's functions run against
# controlled inputs instead of whatever is installed on the machine.

# arkestra_setup: prepare an isolated env, then source arkestra.sh.
# Sets: ARKESTRA, BIN_DIR (on PATH, first), FAKE_HOME (as $HOME).
arkestra_setup() {
  ARKESTRA="${BATS_TEST_DIRNAME}/../arkestra.sh"
  BIN_DIR="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  PATH="${BIN_DIR}:${PATH}"
}

arkestra_teardown() {
  rm -rf "$BIN_DIR" "$FAKE_HOME"
}

# stub_cli <name> <body>: write an executable fake CLI onto PATH.
# The body is the full script after the shebang; it sees "$@".
stub_cli() {
  local name="$1" body="$2"
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$body"
  } > "${BIN_DIR}/${name}"
  chmod +x "${BIN_DIR}/${name}"
}

# source_arkestra: load the functions (main is guarded out when sourced).
source_arkestra() { source "$ARKESTRA"; }
