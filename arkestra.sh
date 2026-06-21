#!/usr/bin/env bash
#
# arkestra.sh - launch a tmux structure of CLI coding agents orchestrated by
# Claude, coordinated via file sentinels. Invoked as `tools agents`.
#
# Design (all pieces proven standalone before assembly):
#   - orchestrator = Claude, always left half of window 0 (fixed)
#   - workers run HEADLESS (narration + diffs stream to pane, process exits,
#     writes .agent-out/<role>.done with exit code). Zoom any pane: Ctrl-b z.
#   - all workers share ONE workspace (picked at launch); the orchestrator
#     sequences writers (two editors on one tree collide); readers run parallel
#   - PRE-FLIGHT PROBE: resolve model (override or CLI's own config default),
#     validate against that CLI's real model list, BLOCK-with-fix on mismatch,
#     then show table + confirm before launching anything.
#
# Layout: orch always pane 0 left half.
#   <=2 workers -> single window (orch left, workers stacked right, main-vertical)
#   >2 workers  -> orch+worker1 in w0; remaining workers 2-per-window (Ctrl-b n)
#
# Roles (fixed priority, unused skipped, no gaps):
#   1 arch    codex     architecture / 2nd opinion
#   2 coding  opencode  complex coding
#   3 impl    pi        direct implementation
#   4 logs    gemini    deep log / investigation
#   5 git     pi-git    git operations (small/fast)
#
# bash 3.2 safe: no associative arrays, no \s in sed, no `timeout`.
set -eu

SESSION="arkestra"
RED='\033[38;5;1m'; GREEN='\033[38;5;2m'; YELLOW='\033[38;5;3m'
BLUE='\033[38;5;4m'; GRAY='\033[38;5;8m'; NC='\033[0m'
die() { printf "${RED}error:${NC} %s\n" "$*" >&2; exit 1; }

PRIORITY="arch coding impl logs git"

# Persistent per-role model defaults (set once via `tools agents set <role>`).
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arkestra"
CONF="$CONF_DIR/agents.conf"

# read a role's saved default from agents.conf (empty if unset)
conf_get() { [ -f "$CONF" ] && awk -v r="$1" '$1==r{print $2; exit}' "$CONF"; }
# write/replace a role's default in agents.conf
conf_set() {
  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
# arkestra per-role model defaults. Resolution order at launch:
#   1. --<role> <model> flag (this session)
#   2. this file (your persistent choice)        <- set via `tools agents set <role>`
#   3. the CLI's own configured default (fallback)
# Format: <role> <model>   (one per line). Set with the picker; do not invent ids.
EOF
  fi
  local tmp="$CONF.tmp"
  grep -v "^$1[[:space:]]" "$CONF" > "$tmp" 2>/dev/null || true
  echo "$1 $2" >> "$tmp"
  mv "$tmp" "$CONF"
}

usage() {
  cat <<'EOF'
tools agents - launch orchestrated CLI agent swarm in tmux

  tools agents [roles...] [--<role> model] ...

ROLES (fixed priority, give any subset; unused are skipped):
  arch    codex     architecture / second opinion
  coding  opencode  complex coding
  impl    pi        direct implementation
  logs    gemini    deep log / investigation
  git     git ops via pi (small/fast)

OVERRIDE a role's model for this session (else the saved/CLI default):
  tools agents coding arch --coding opencode/claude-opus-4-8 --arch gpt-5.5

SET a persistent per-role default (picker lists the CLI's real models):
  tools agents set coding        # then pick from the list; saved to agents.conf

Model resolution per role: --flag  >  agents.conf  >  the CLI's own default.
Bare `tools agents` probes DEFAULT roles (coding arch git) and confirms.
The orchestrator (Claude) is always launched as pane 0; you attach to watch.
EOF
}

# ---- role -> CLI label / dispatch identity ----
cli_for() { case "$1" in
  arch) echo codex;; coding) echo opencode;; impl) echo pi;;
  logs) echo gemini;; git) echo pi-git;; esac; }

# ---- per-role: configured default model ----
default_for() { case "$1" in
  arch)   grep -iE '^[[:space:]]*model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/' ;;
  coding) grep -iE '"model"[[:space:]]*:' "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null \
            | head -1 | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' ;;
  impl)   pi --list-models 2>/dev/null | sed -n '2p' | awk '{print $1"/"$2}' ;;
  logs)   echo "gemini" ;;                 # gemini CLI: provider fixed
  git)    pi --list-models 2>/dev/null | grep -i glm | head -1 | awk '{print $1"/"$2}' ;;
esac; }

# ---- per-role: is model valid for that CLI? ----
valid_for() { local r="$1" m="$2"; [ -n "$m" ] || return 1; case "$r" in
  arch)        codex --help >/dev/null 2>&1 ;;                       # trust config/-m
  coding)      opencode models 2>/dev/null | grep -qx "$m" ;;
  impl|git)    pi --list-models 2>/dev/null | grep -q "${m##*/}" ;;
  logs)        command -v gemini >/dev/null 2>&1 ;;
esac; }

# ---- per-role: the REAL model list from that CLI (one id per line) ----
# Sourced straight from each CLI; nothing invented.
list_models_for() { case "$1" in
  coding)    opencode models 2>/dev/null ;;
  impl|git)  pi --list-models 2>/dev/null | sed -n '2,$p' | awk '{print $1"/"$2}' ;;
  arch)      pi --list-models 2>/dev/null | awk '/openai-codex/{print $2}' ;;  # gpt-5.x ids
  logs)      printf 'gemini\n' ;;
esac; }

suggest_for() { list_models_for "$1" | head -6 | sed 's/^/      /'; }

# ---- per-role: the headless command that runs ONE task and exits ----
# Used by `dispatch`. Writes the sentinel with exit code on completion.
worker_cmd() {
  local role="$1" model="$2" task="$3"
  case "$role" in
    arch)   echo "codex exec -s workspace-write -m '$model' '$task'";;
    coding) echo "opencode run -m '$model' '$task'";;
    impl)   echo "pi --model '$model' -p '$task'";;
    git)    echo "pi --model '$model' -p '$task'";;
    logs)   echo "gemini -p '$task'";;
  esac
}

# ---- worker_idle: the pane just shows it's ready; orchestrator dispatches later.
worker_idle() {
  local role="$1" model="$2"
  echo "clear; printf '[$role pane ready - model $model]\\n[idle; orchestrator dispatches tasks here]\\n'"
}

# ---- order a want-list by PRIORITY, drop unused, no gaps ----
order_roles() { local want=" $* " out=""; for p in $PRIORITY; do
  case "$want" in *" $p "*) out="$out $p";; esac; done; echo $out; }

# =====================================================================
# PRE-FLIGHT PROBE: resolve + validate + show + confirm. Returns nonzero
# (and prints fixes) if any role is unavailable -> caller must not launch.
# Populates RESOLVED_<role>=model on success.
# =====================================================================
probe() {
  local roles="$1"; shift
  local blocked=0
  printf "\n  ${BLUE}%-8s %-10s %-30s %s${NC}\n" ROLE CLI MODEL SOURCE
  printf "  %-8s %-10s %-30s %s\n" -------- ---------- ------------------------------ ------
  for r in $roles; do
    local cli model src ovar
    cli=$(cli_for "$r")
    eval "model=\${OVR_$r:-}"
    if [ -n "$model" ]; then src="override"
    elif model=$(conf_get "$r"); [ -n "$model" ]; then src="arkestra default"
    else model=$(default_for "$r"); src="CLI default"; fi
    if valid_for "$r" "$model"; then
      printf "  %-8s %-10s %-30s %s  ${GREEN}[OK]${NC}\n" "$r" "$cli" "$model" "$src"
      eval "RESOLVED_$r=\"\$model\""
    else
      printf "  %-8s %-10s %-30s %s  ${RED}[UNAVAILABLE]${NC}\n" "$r" "$cli" "$model" "$src"
      printf "      ${YELLOW}^ '%s' not found for %s. Available (sample):${NC}\n" "$model" "$cli"
      suggest_for "$r"
      blocked=1
    fi
  done
  if [ "$blocked" -eq 1 ]; then
    printf "\n  ${RED}BLOCKED:${NC} fix the model(s) above (--<role> <model>) and rerun. Nothing launched.\n"
    return 1
  fi
  printf "\n  Launch this structure? [y/N] "
  local ans; read -r ans || true
  case "$ans" in y|Y|yes) return 0 ;; *) echo "  aborted."; return 2 ;; esac
}

# =====================================================================
# WORKSPACE PICKER: all workers share ONE workspace (no per-role worktrees).
# Default = the current checkout. Also offers other local branches and a fresh
# worktree off a base. Echoes the chosen working directory.
# =====================================================================
pick_workspace() {
  local repo="$1"
  local cur; cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  printf "${BLUE}workspace:${NC} all workers share one tree (orchestrator sequences writers).\n" >&2
  printf "  current branch: ${GREEN}%s${NC}  (%s)\n" "$cur" "$repo" >&2
  local branches; branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | grep -v "^$cur$")
  [ -n "$branches" ] && { printf "  other local branches: %s\n" "$(echo $branches)" >&2; }
  printf "  [Enter]=use current  |  <branch>=checkout it here  |  new:<base>=fresh worktree\n  > " >&2
  local choice; read -r choice || true
  case "$choice" in
    "")        echo "$repo" ;;                                  # current checkout
    new:*)     local base="${choice#new:}"; local wt="$repo/.worktrees/agents-$$"
               git -C "$repo" worktree add -q "$wt" "${base:-$cur}" >&2 || die "worktree add failed"
               echo "$wt" ;;
    *)         git -C "$repo" rev-parse --verify -q "$choice" >/dev/null \
                 || die "no such branch '$choice'"
               git -C "$repo" checkout -q "$choice" >&2 || die "checkout '$choice' failed"
               echo "$repo" ;;
  esac
}

# =====================================================================
# LAUNCH: build tmux structure; all workers run in the SHARED workspace.
# =====================================================================
launch() {
  local roles="$1" repo="$2" ws="$3"
  local out="$ws/.agent-out"; mkdir -p "$out"
  : > "$out/PANES.md"   # role -> pane map the orchestrator reads to dispatch

  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -n w0 -c "$ws"   # pane 0 = orchestrator (Claude)
  tmux set -t "$SESSION" mouse on              # click to focus any pane (bug: approve dialogs)

  local brief="$(cd "$(dirname "$0")" && pwd)/ORCHESTRATOR.md"
  if [ -f "$brief" ]; then
    tmux send-keys -t "$SESSION:w0" "claude --append-system-prompt-file '$brief'" Enter
  else
    tmux send-keys -t "$SESSION:w0" "claude" Enter
  fi

  set -- $roles
  local n=$#

  # spawn: start the worker's CLI IDLE (no task) and record its pane in PANES.md.
  # The orchestrator dispatches real tasks into these panes via tmux send-keys.
  spawn() {
    local role="$1" target="$2" model launch_idle
    eval "model=\${RESOLVED_$role}"
    launch_idle=$(worker_idle "$role" "$model")
    [ -n "$launch_idle" ] && tmux send-keys -t "$target" "$launch_idle" Enter
    printf '%-7s pane=%s  model=%s\n' "$role" "$target" "$model" >> "$out/PANES.md"
  }

  if [ "$n" -le 2 ]; then
    # orch left, workers stacked right; force EXACT 50/50 horizontal split.
    [ "$n" -ge 1 ] && { tmux split-window -h -p 50 -t "$SESSION:w0" -c "$ws"; spawn "$1" "$SESSION:w0.1"; }
    [ "$n" -eq 2 ] && { tmux split-window -v -p 50 -t "$SESSION:w0.1" -c "$ws"; spawn "$2" "$SESSION:w0.2"; }
    tmux select-pane -t "$SESSION:w0.0"          # focus orchestrator
  else
    tmux split-window -h -p 50 -t "$SESSION:w0" -c "$ws"; spawn "$1" "$SESSION:w0.1"; shift
    local win=1
    while [ "$#" -gt 0 ]; do
      tmux new-window -t "$SESSION" -n "w$win" -c "$ws"; spawn "$1" "$SESSION:w$win.0"; shift
      [ "$#" -gt 0 ] && { tmux split-window -h -p 50 -t "$SESSION:w$win" -c "$ws"; spawn "$1" "$SESSION:w$win.1"; shift; }
      win=$((win+1))
    done
  fi

  printf "\n${GREEN}launched.${NC} attach:  ${BLUE}tmux attach -t %s${NC}\n" "$SESSION"
  printf "  ${GRAY}zoom a pane: Ctrl-b z   next window: Ctrl-b n   sentinels: %s/${NC}\n" ".agent-out"
}

# =====================================================================
# `tools agents dispatch <role> "<task>"` — the ORCHESTRATOR uses this to run a
# real headless task in a role's pane. Looks up the pane+model from PANES.md,
# sends the headless command (which writes .agent-out/<role>.done on exit).
# =====================================================================
cmd_dispatch() {
  local role="${1:-}"; shift || true
  local task="$*"
  [ -n "$role" ] && [ -n "$task" ] || die "dispatch <role> \"<task>\""
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repo"
  local out="$repo/.agent-out"
  local line; line=$(awk -v r="$role" '$1==r{print; exit}' "$out/PANES.md" 2>/dev/null)
  [ -n "$line" ] || die "role '$role' not found in PANES.md (is the swarm running?)"
  local pane model; pane=$(echo "$line" | sed -E 's/.*pane=([^ ]+).*/\1/')
  model=$(echo "$line" | sed -E 's/.*model=([^ ]+).*/\1/')
  local cmd; cmd=$(worker_cmd "$role" "$model" "$task")
  rm -f "$out/$role.done"
  tmux send-keys -t "$pane" \
    "$cmd; echo \$? > '$out/$role.done'; echo '[$role done; sentinel written]'" Enter
  printf "${GREEN}dispatched${NC} %s -> %s  (wait on %s)\n" "$role" "$pane" ".agent-out/$role.done"
}

# =====================================================================
# `tools agents set <role>` — pick a model from the role's CLI, save to conf.
# =====================================================================
cmd_set() {
  local role="${1:-}"
  case " $PRIORITY " in *" $role "*) :;; *) die "set <role>: one of $PRIORITY";; esac
  local cli; cli=$(cli_for "$role")
  printf "${BLUE}set %s${NC} (cli: %s) — models from the CLI itself:\n" "$role" "$cli" >&2
  local models; models=$(list_models_for "$role")
  [ -n "$models" ] || die "no models returned by $cli for role '$role'"
  local i=1; local list=""
  while IFS= read -r m; do printf "  %2d) %s\n" "$i" "$m" >&2; list="$list$m
"; i=$((i+1)); done <<EOF
$models
EOF
  printf "  pick number (or paste exact id): " >&2
  local pick; read -r pick || true
  local chosen
  if echo "$pick" | grep -qE '^[0-9]+$'; then
    chosen=$(echo "$list" | sed -n "${pick}p")
  else chosen="$pick"; fi
  [ -n "$chosen" ] || die "nothing picked"
  conf_set "$role" "$chosen"
  printf "${GREEN}saved:${NC} %s -> %s  (%s)\n" "$role" "$chosen" "$CONF" >&2
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    set) shift; cmd_set "$@"; exit 0 ;;
    dispatch) shift; cmd_dispatch "$@"; exit 0 ;;
    install) exec bash "$(cd "$(dirname "$0")" && pwd)/install.sh" ;;
  esac
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  command -v claude >/dev/null 2>&1 || die "claude (orchestrator) is required"
  git rev-parse --git-dir >/dev/null 2>&1 || die "run inside a git repository"
  local repo; repo=$(git rev-parse --show-toplevel)

  # parse: positional roles + --<role> model overrides
  local want=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --arch|--coding|--impl|--logs|--git)
        local rr="${1#--}"; shift; [ "$#" -gt 0 ] || die "--$rr needs a model"
        eval "OVR_$rr=\"\$1\""; want="$want $rr" ;;
      arch|coding|impl|logs|git) want="$want $1" ;;
      *) die "unknown arg '$1' (try: tools agents --help)" ;;
    esac
    shift
  done
  [ -n "$want" ] || want="coding arch git"   # bare default set

  local roles; roles=$(order_roles $want)
  [ -n "$roles" ] || die "no valid roles"

  local ws; ws=$(pick_workspace "$repo") || exit $?
  printf "${BLUE}pre-flight:${NC} probing %s  ${GRAY}(workspace: %s)${NC}\n" "$roles" "$ws"
  probe "$roles" || exit $?
  launch "$roles" "$repo" "$ws"
}

main "$@"
