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
#   4 logs    agy       deep log / investigation
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

# conf line format: <role> <harness> <model>
# saved harness's model (field 3); empty if role unset
conf_get()     { [ -f "$CONF" ] && awk -v r="$1" '$1==r{print $3; exit}' "$CONF"; }
# saved harness (field 2); empty if role unset
conf_harness() { [ -f "$CONF" ] && awk -v r="$1" '$1==r{print $2; exit}' "$CONF"; }
# write/replace a role's harness+model in agents.conf
conf_set() {
  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
# arkestra per-role overrides. EMPTY by default -> each role uses its default
# harness (CLI) and that CLI's own configured model. Add a line ONLY to override.
# Resolution: 1) --<role> flag (session) 2) this file 3) the default.
# Format: <role> <harness> <model>   (set via `tools agents set <role>`).
EOF
  fi
  local tmp="$CONF.tmp"
  grep -v "^$1[[:space:]]" "$CONF" > "$tmp" 2>/dev/null || true
  echo "$1 $2 $3" >> "$tmp"
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
  logs    agy       deep log / investigation
  git     git ops via pi (small/fast)

OVERRIDE a role's model for this session (else the saved/CLI default):
  tools agents coding arch --coding opencode/claude-opus-4-8 --arch gpt-5.5

SET a persistent per-role default (picker lists the CLI's real models):
  tools agents set coding        # then pick from the list; saved to agents.conf

Model resolution per role: --flag  >  agents.conf  >  the CLI's own default.
Bare `tools agents` probes DEFAULT roles (coding arch git) and confirms.
The orchestrator (Claude) is always launched as pane 0; you attach to watch.

OTHER COMMANDS:
  tools agents dispatch <role> "<task>"  (the orchestrator delegates a task)
  tools agents stop [--keep-out]         stop the swarm: kill session, prune
                                         worktrees, clear .agent-out
  tools agents install                   check/install deps (macOS + Arch/Linux)
  tools agents uninstall                 remove arkestra's own files (config dir)
EOF
}

# ---- role -> DEFAULT harness (the hardwired fallback; overridable via conf/flag) ----
default_harness() { case "$1" in
  arch) echo codex;; coding) echo opencode;; impl) echo pi;;
  logs) echo agy;; git) echo pi;; esac; }

# ---- resolve a role's harness: --flag override > agents.conf > default_harness ----
harness_for() {
  local role="$1" h
  eval "h=\${OVH_$role:-}"; [ -n "$h" ] && { echo "$h"; return; }
  h=$(conf_harness "$role"); [ -n "$h" ] && { echo "$h"; return; }
  default_harness "$role"
}

# ---- per-HARNESS: that CLI's configured default model ----
default_for() { case "$1" in   # $1 = harness
  codex)    grep -iE '^[[:space:]]*model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null \
              | head -1 | sed -E 's/.*"([^"]+)".*/\1/' ;;
  opencode) # opencode's ACTIVE model = recent[0] in its state file (what the TUI launches
            # with), NOT opencode.jsonc's "model" (a stale profile). Fall back to jsonc.
            local mj="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/model.json"
            if [ -f "$mj" ]; then
              sed -E 's/.*"recent":\[\{"providerID":"([^"]+)","modelID":"([^"]+)".*/\1\/\2/' "$mj" 2>/dev/null | head -1
            else
              grep -iE '"model"[[:space:]]*:' "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null \
                | head -1 | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
            fi ;;
  pi)       pi_default ;;
  agy)      agy_default ;;
esac; }

# agy's active model: it stores no user default, but logs the selected model
# label on each run. Read the newest cli log; fall back to "agy default".
agy_default() {
  local log; log=$(ls -t "$HOME/.gemini/antigravity-cli/log/"cli-*.log 2>/dev/null | head -1)
  if [ -n "$log" ]; then
    local m; m=$(grep -oE 'selected model override to backend: label="[^"]+"' "$log" 2>/dev/null \
      | tail -1 | sed -E 's/.*label="([^"]+)".*/\1/')
    [ -n "$m" ] && { echo "$m"; return; }
  fi
  echo "agy default"
}

# pi's configured default provider/model from ~/.pi/agent/settings.json
pi_default() {
  local s="$HOME/.pi/agent/settings.json"
  [ -f "$s" ] || { pi --list-models 2>/dev/null | sed -n '2p' | awk '{print $1"/"$2}'; return; }
  local prov mdl
  prov=$(sed -E -n 's/.*"defaultProvider"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$s" | head -1)
  mdl=$(sed -E -n 's/.*"defaultModel"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$s" | head -1)
  [ -n "$mdl" ] || { pi --list-models 2>/dev/null | sed -n '2p' | awk '{print $1"/"$2}'; return; }
  if [ -n "$prov" ]; then echo "$prov/$mdl"; else echo "$mdl"; fi
}

# ---- per-HARNESS: is model valid / callable for that CLI? ----
valid_for() { local h="$1" m="$2"; [ -n "$m" ] || return 1; case "$h" in   # $1 = harness
  codex)     codex --help >/dev/null 2>&1 ;;                       # trust config/-m
  opencode)  opencode models 2>/dev/null | grep -qx "$m" ;;
  pi)        pi --list-models 2>/dev/null | grep -q "${m##*/}" ;;
  agy)       command -v agy >/dev/null 2>&1 ;;
  *)         command -v "$h" >/dev/null 2>&1 ;;                     # unknown harness: just exists
esac; }

# ---- per-HARNESS: the REAL model list from that CLI (one id per line) ----
# Sourced straight from each CLI; nothing invented.
list_models_for() { case "$1" in   # $1 = harness
  opencode)  opencode models 2>/dev/null ;;
  pi)        pi --list-models 2>/dev/null | sed -n '2,$p' | awk '{print $1"/"$2}' ;;
  codex)     pi --list-models 2>/dev/null | awk '/openai-codex/{print $2}' ;;  # gpt-5.x ids
  agy)       agy models 2>/dev/null ;;
esac; }

suggest_for() { list_models_for "$1" | head -6 | sed 's/^/      /'; }

# ---- shquote: wrap a string in single quotes, escaping any inner ' safely.
# Without this, a task/model containing a single quote breaks shell parsing
# (the worker sees stray flags -> "Unknown option: -"). Idiom: ' -> '\''
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- per-HARNESS: the headless command that runs ONE task and exits ----
# Used by `dispatch`. Writes the sentinel with exit code on completion.
worker_cmd() {
  local harness="$1" model="$2" task="$3" m t
  m=$(shquote "$model"); t=$(shquote "$task")
  case "$harness" in
    codex)    echo "codex exec -s workspace-write -m $m $t";;
    opencode) echo "opencode run -m $m $t";;
    pi)       echo "pi --model $m -p $t";;
    agy)      echo "agy --model $m -p $t";;
    *)        echo "$harness -p $t";;   # unknown: best-effort headless
  esac
}

# ---- banner_for: a compact, fancy idle banner for a worker pane (no echoed cmd).
# Printed by spawn() via a cleared line so only the banner shows, not the command.
banner_for() {
  local role="$1" model="$2"
  printf '\033[38;5;8m┌─ \033[38;5;4m%s\033[38;5;8m ─ %s\n│  \033[38;5;3midle\033[38;5;8m · orchestrator dispatches here\n└─\033[0m\n' \
    "$role" "$model"
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
    local harness model src
    harness=$(harness_for "$r")            # --flag > conf > default_harness
    eval "model=\${OVR_$r:-}"
    if [ -n "$model" ]; then src="override"
    elif model=$(conf_get "$r"); [ -n "$model" ]; then src="arkestra default"
    else model=$(default_for "$harness"); src="CLI default"; fi
    if valid_for "$harness" "$model"; then
      printf "  %-8s %-10s %-30s %s  ${GREEN}[OK]${NC}\n" "$r" "$harness" "$model" "$src"
      eval "RESOLVED_$r=\"\$model\""; eval "RESOLVED_H_$r=\"\$harness\""
    else
      printf "  %-8s %-10s %-30s %s  ${RED}[UNAVAILABLE]${NC}\n" "$r" "$harness" "$model" "$src"
      printf "      ${YELLOW}^ '%s' not found for %s. Available (sample):${NC}\n" "$model" "$harness"
      suggest_for "$harness"
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
    local role="$1" target="$2" model harness
    eval "model=\${RESOLVED_$role}"; eval "harness=\${RESOLVED_H_$role}"
    # write the idle banner to a per-role file, then have the pane cat+clear it.
    # Sending a short `clear; cat FILE` avoids the long-printf line wrapping/echo.
    banner_for "$role" "$harness/$model" > "$out/.banner-$role"
    tmux send-keys -t "$target" "clear; cat '$out/.banner-$role'" Enter
    printf '%-7s pane=%s  harness=%s  model=%s\n' "$role" "$target" "$harness" "$model" >> "$out/PANES.md"
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
  local pane harness model
  pane=$(echo "$line"    | sed -E 's/.*pane=([^ ]+).*/\1/')
  harness=$(echo "$line" | sed -E 's/.*harness=([^ ]+).*/\1/')
  model=$(echo "$line"   | sed -E 's/.*model=(.+)$/\1/')   # model is last; may contain spaces
  local cmd; cmd=$(worker_cmd "$harness" "$model" "$task")
  rm -f "$out/$role.done"
  tmux send-keys -t "$pane" \
    "$cmd; echo \$? > '$out/$role.done'; echo '[$role done; sentinel written]'" Enter
  printf "${GREEN}dispatched${NC} %s -> %s  (wait on %s)\n" "$role" "$pane" ".agent-out/$role.done"
}

# =====================================================================
# `tools agents stop` — tear down the running swarm: kill the tmux session,
# prune any worktrees it created, and clear .agent-out scratch (with --keep-out
# to leave sentinels/PANES.md for inspection).
# =====================================================================
cmd_stop() {
  local keep_out=0
  case "${1:-}" in --keep-out) keep_out=1 ;; esac
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" && printf "${GREEN}stopped${NC} tmux session '%s'\n" "$SESSION"
  else
    printf "${GRAY}no running '%s' session.${NC}\n" "$SESSION"
  fi
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$repo" ]; then
    # remove only the fresh worktrees arkestra creates (.worktrees/agents-*)
    if [ -d "$repo/.worktrees" ]; then
      local wt
      for wt in "$repo"/.worktrees/agents-*; do
        [ -d "$wt" ] && git -C "$repo" worktree remove --force "$wt" 2>/dev/null
      done
      git -C "$repo" worktree prune 2>/dev/null
      rmdir "$repo/.worktrees" 2>/dev/null || true
    fi
    if [ "$keep_out" -eq 0 ] && [ -d "$repo/.agent-out" ]; then
      rm -rf "$repo/.agent-out" && printf "  ${GRAY}cleared .agent-out${NC}\n"
    fi
  fi
}

ALL_HARNESSES="codex opencode pi agy"   # claude excluded (it is the orchestrator)

# =====================================================================
# `tools agents set <role>` — pick HARNESS, then a model from it; save to conf.
# =====================================================================
cmd_set() {
  local role="${1:-}"
  case " $PRIORITY " in *" $role "*) :;; *) die "set <role>: one of $PRIORITY";; esac

  # 1) pick the harness (any installed CLI; default = the role's default harness)
  local def; def=$(default_harness "$role")
  printf "${BLUE}set %s${NC} — pick a harness (CLI):\n" "$role" >&2
  local i=1 hlist=""
  for h in $ALL_HARNESSES; do
    local mark=""; [ "$h" = "$def" ] && mark=" ${GRAY}(default)${NC}"
    command -v "$h" >/dev/null 2>&1 && printf "  %d) %b%b\n" "$i" "$h" "$mark" >&2
    hlist="$hlist$h
"; i=$((i+1))
  done
  printf "  pick a number [Enter=%s]: " "$def" >&2
  local hp; read -r hp || true
  local harness
  if [ -z "$hp" ]; then harness="$def"
  elif echo "$hp" | grep -qE '^[0-9]+$'; then harness=$(echo "$hlist" | sed -n "${hp}p")
  else harness="$hp"; fi
  [ -n "$harness" ] || die "no harness picked"

  # 2) pick a model from THAT harness (or type any callable id)
  printf "${BLUE}  harness %s${NC} — models it reports:\n" "$harness" >&2
  local models; models=$(list_models_for "$harness")
  local j=1 list=""
  if [ -n "$models" ]; then
    while IFS= read -r m; do printf "  %2d) %s\n" "$j" "$m" >&2; list="$list$m
"; j=$((j+1)); done <<EOF
$models
EOF
  else
    printf "  ${GRAY}(no models listed — type any callable id directly)${NC}\n" >&2
  fi
  printf "  pick a number, or type/paste any model id: " >&2
  local pick; read -r pick || true
  local chosen
  if echo "$pick" | grep -qE '^[0-9]+$' && [ -n "$list" ]; then
    chosen=$(echo "$list" | sed -n "${pick}p")
  else chosen="$pick"; fi
  [ -n "$chosen" ] || die "nothing picked"

  conf_set "$role" "$harness" "$chosen"
  printf "${GREEN}saved:${NC} %s -> %s / %s  (%s)\n" "$role" "$harness" "$chosen" "$CONF" >&2
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    set) shift; cmd_set "$@"; exit 0 ;;
    dispatch) shift; cmd_dispatch "$@"; exit 0 ;;
    stop) shift; cmd_stop "$@"; exit 0 ;;
    install) exec bash "$(cd "$(dirname "$0")" && pwd)/install.sh" ;;
    uninstall) exec bash "$(cd "$(dirname "$0")" && pwd)/install.sh" --uninstall ;;
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
