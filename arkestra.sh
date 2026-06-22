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
BLUE='\033[38;5;4m'; MAGENTA='\033[38;5;5m'; CYAN='\033[38;5;6m'
WHITE='\033[38;5;7m'; GRAY='\033[38;5;8m'; B='\033[1m'; DIM='\033[2m'; NC='\033[0m'
die() { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

PRIORITY="arch coding impl logs git"

# ---- UI primitives (clean minimal; gum where available, ANSI fallback) ----
# ARKESTRA_NO_GUM=1 forces the ANSI fallback (useful for testing / no-tty).
if [ "${ARKESTRA_NO_GUM:-0}" = 1 ]; then HAS_GUM=0
elif command -v gum >/dev/null 2>&1; then HAS_GUM=1; else HAS_GUM=0; fi

ui_title() {
  if [ -n "${2:-}" ]; then printf "\n${B}${BLUE}%s${NC} ${DIM}%s${NC}\n" "$1" "$2" >&2
  else printf "\n${B}${BLUE}%s${NC}\n" "$1" >&2; fi
}
ui_rule()  { printf "${GRAY}%s${NC}\n" "────────────────────────────────────────────────" >&2; }
ui_ok()    { printf "  ${GREEN}✓${NC} %s\n" "$1" >&2; }
ui_err()   { printf "  ${RED}✗${NC} %s\n" "$1" >&2; }
ui_kv()    { printf "  ${GRAY}%-9s${NC} %s\n" "$1" "$2" >&2; }

# ui_choose <header> <newline-separated-options>  -> echoes the chosen line.
# gum choose: arrow-key menu (green cursor/match). long lists are scrollable.
# fallback: numbered prompt. Either way you can also type a custom value.
ui_choose() {
  local header="$1" opts="$2"
  if [ "$HAS_GUM" = 1 ]; then
    local chosen
    chosen=$(printf '%s' "$opts" | gum choose --header="$header" --height=14 \
      --cursor="❯ " --cursor.foreground=2 --header.foreground=8 2>/dev/tty)
    printf '%s' "$chosen"
  else
    printf "${DIM}%s${NC}\n" "$header" >&2
    local i=1; printf '%s\n' "$opts" | while IFS= read -r o; do
      [ -n "$o" ] && printf "  ${CYAN}%2d${NC} %s\n" "$i" "$o" >&2; i=$((i+1)); done
    printf "  ${GRAY}number, or type any value:${NC} " >&2
    local pick; read -r pick || true
    if printf '%s' "$pick" | grep -qE '^[0-9]+$'; then
      printf '%s' "$opts" | sed -n "${pick}p"
    else printf '%s' "$pick"; fi
  fi
}

# ui_input <prompt>  -> free-text entry (gum input or read).
ui_input() {
  if [ "$HAS_GUM" = 1 ]; then
    gum input --prompt="  $1 " --placeholder="model id…" 2>/dev/tty
  else
    printf "  %s " "$1" >&2; local v; read -r v || true; printf '%s' "$v"
  fi
}

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
tools agents - launch an orchestrated CLI agents team in tmux

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
  tools agents stop [--keep-out]         stop the team: kill session, prune
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
# Used by `dispatch`. Each runs NON-INTERACTIVE with auto-approved permissions so
# a worker never hangs waiting for a prompt no one will answer (no human watches a
# pane mid-dispatch). codex stays sandboxed to the workspace; the rest skip prompts.
worker_cmd() {
  local harness="$1" model="$2" task="$3" m t
  m=$(shquote "$model"); t=$(shquote "$task")
  case "$harness" in
    codex)    echo "codex exec -s workspace-write -m $m $t";;   # already non-interactive in-workspace
    opencode) echo "opencode run --dangerously-skip-permissions -m $m $t";;
    pi)       echo "pi --approve --model $m -p $t";;
    agy)      echo "agy --dangerously-skip-permissions --model $m -p $t";;
    *)        echo "$harness -p $t";;   # unknown: best-effort headless
  esac
}

# ---- banner_for: a compact, fancy idle banner for a worker pane (no echoed cmd).
# Printed by spawn() via a cleared line so only the banner shows, not the command.
banner_for() {
  local role="$1" harness="$2" model="$3"
  printf '\033[38;5;8m┌─ \033[38;5;4m%s\033[38;5;8m · \033[38;5;6m%s\033[38;5;8m · %s\n│  \033[38;5;3midle\033[38;5;8m · orchestrator dispatches here\n└─\033[0m\n' \
    "$role" "$harness" "$model"
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
  ui_title "pre-flight"
  printf "    ${GRAY}${B}%-6s  %-9s  %-26s  %s${NC}\n" ROLE HARNESS MODEL SOURCE >&2
  for r in $roles; do
    local harness model src
    harness=$(harness_for "$r")            # --flag > conf > default_harness
    eval "model=\${OVR_$r:-}"
    if [ -n "$model" ]; then src="flag"
    elif model=$(conf_get "$r"); [ -n "$model" ]; then src="config"
    else model=$(default_for "$harness"); src="cli"; fi
    if valid_for "$harness" "$model"; then
      printf "  ${GREEN}●${NC} ${B}%-6s${NC}  ${CYAN}%-9s${NC}  %-26s  ${DIM}%s${NC}\n" \
        "$r" "$harness" "$model" "$src" >&2
      eval "RESOLVED_$r=\"\$model\""; eval "RESOLVED_H_$r=\"\$harness\""
    else
      printf "  ${RED}●${NC} ${B}%-6s${NC}  ${CYAN}%-9s${NC}  ${RED}%-26s${NC}  ${DIM}%s${NC}\n" \
        "$r" "$harness" "$model" "$src" >&2
      printf "    ${YELLOW}↳ not available for %s. try:${NC} %s\n" \
        "$harness" "$(list_models_for "$harness" | head -3 | tr '\n' ' ')" >&2
      blocked=1
    fi
  done
  if [ "$blocked" -eq 1 ]; then
    printf "\n  ${RED}✗ blocked${NC} ${DIM}— fix the model(s) above, then rerun. nothing launched.${NC}\n" >&2
    return 1
  fi
  printf "\n" >&2
  if [ "$HAS_GUM" = 1 ]; then
    gum confirm "Launch this team?" --affirmative="Launch" --negative="Cancel" \
      --selected.background="2" --selected.foreground="0" && return 0
    printf "  ${DIM}cancelled.${NC}\n" >&2; return 2
  fi
  printf "  ${B}launch this team?${NC} ${DIM}[y/N]${NC} " >&2
  local ans; read -r ans || true
  case "$ans" in y|Y|yes) return 0 ;; *) printf "  ${DIM}cancelled.${NC}\n" >&2; return 2 ;; esac
}

# =====================================================================
# WORKSPACE PICKER: all workers share ONE workspace (no per-role worktrees).
# Default = the current checkout. Also offers other local branches and a fresh
# worktree off a base. Echoes the chosen working directory.
# =====================================================================
pick_workspace() {
  local repo="$1"
  local cur; cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  ui_title "workspace" "all workers share one tree"

  # build menu: current branch first, then other branches, then "new worktree".
  local opts="● $cur  (current)
"
  local b; for b in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null); do
    [ "$b" = "$cur" ] && continue; opts="$opts○ $b
"
  done
  opts="$opts+ new worktree off $cur"

  local pick; pick=$(ui_choose "where should the team work?" "$opts")
  [ -n "$pick" ] || { echo "$repo"; return; }                # default = current
  case "$pick" in
    *"(current)") echo "$repo" ;;
    "+ new worktree"*)
        # a worktree needs its OWN branch — two worktrees can't share one (e.g.
        # 'master' is already checked out here). Branch a fresh one off $cur.
        local wt="$repo/.worktrees/agents-$$" br="agents/$$"
        git -C "$repo" worktree add -q -b "$br" "$wt" "$cur" >&2 \
          || die "worktree add failed"
        ui_ok "fresh worktree ${wt##*/} on branch $br (off $cur)"; echo "$wt" ;;
    "○ "*)  local br="${pick#○ }"; br="${br%% *}"
        git -C "$repo" checkout -q "$br" >&2 || die "checkout '$br' failed"
        ui_ok "checked out $br"; echo "$repo" ;;
    *)  echo "$repo" ;;
  esac
}

# =====================================================================
# style_session — modern status bar + pane borders for the arkestra session.
# Uses omarchy terminal palette slots (colour1..8) so it tracks the theme.
# =====================================================================
style_session() {
  local s="$SESSION"
  # session-scoped chrome
  tmux set -t "$s" mouse on
  tmux set -t "$s" status-position top
  tmux set -t "$s" status-justify left
  tmux set -t "$s" status-style "bg=colour0,fg=colour8"
  tmux set -t "$s" status-left  " #[fg=colour4,bold]arkestra#[default]   "
  tmux set -t "$s" status-left-length 20
  tmux set -t "$s" status-right "#[fg=colour8]%H:%M "
  tmux set -t "$s" status-right-length 10
  tmux set -t "$s" pane-border-status off
  tmux set -t "$s" pane-active-border-style "fg=colour2"
  tmux set -t "$s" pane-border-style "fg=colour8"
  tmux set -t "$s" automatic-rename off
  tmux set -t "$s" allow-rename off
  # WINDOW options are per-window — set GLOBALLY (-g) so EVERY window (incl. ones
  # created later) uses our format. Session-scope only hits the active window, so
  # new windows fell back to the global default (#I:#W#F = the index + - and *).
  # Safe: the user has no ~/.tmux.conf window-status customization to clobber.
  tmux setw -g window-status-format         "#[fg=colour8] #W #[default]"
  tmux setw -g window-status-current-format "#[fg=colour2,bold] #W #[default]"
  tmux setw -g window-status-separator " "
  tmux setw -g window-status-activity-style "none"
  tmux setw -g window-status-bell-style "none"
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
  style_session                                       # modern status bar + pane borders

  local brief="$(cd "$(dirname "$0")" && pwd)/ORCHESTRATOR.md"
  if [ -f "$brief" ]; then
    tmux send-keys -t "$SESSION:w0" "claude --append-system-prompt-file '$brief'" Enter
  else
    tmux send-keys -t "$SESSION:w0" "claude" Enter
  fi

  set -- $roles
  local n=$#

  # idle_cmd: the shell command a worker pane LAUNCHES with — print the banner,
  # then exec an interactive shell. The banner is program OUTPUT, never a typed
  # command, so it can't echo or wrap (the old `send-keys cat` bug).
  idle_cmd() {
    local role="$1" model harness
    eval "model=\${RESOLVED_$role}"; eval "harness=\${RESOLVED_H_$role}"
    banner_for "$role" "$harness" "$model" > "$out/.banner-$role"
    echo "clear; cat $(shquote "$out/.banner-$role"); exec ${SHELL:-/bin/zsh}"
  }
  record() {  # role  pane_id
    local role="$1" pid="$2" model harness
    eval "model=\${RESOLVED_$role}"; eval "harness=\${RESOLVED_H_$role}"
    printf '%-7s pane=%s  harness=%s  model=%s\n' "$role" "$pid" "$harness" "$model" >> "$out/PANES.md"
  }
  # split a pane and run the worker's idle command; echo the NEW pane's id.
  split_idle() {  # role  target  flags...
    local role="$1" tgt="$2"; shift 2
    tmux split-window -P -F '#{pane_id}' "$@" -t "$tgt" -c "$ws" "$(idle_cmd "$role")"
  }

  if [ "$n" -le 2 ]; then
    [ "$n" -ge 1 ] && record "$1" "$(split_idle "$1" "$SESSION:w0" -h -p 50)"
    [ "$n" -eq 2 ] && record "$2" "$(split_idle "$2" "$SESSION:w0.1" -v -p 50)"
    tmux rename-window -t "$SESSION:w0" "orch·$1${2:+·$2}"
    tmux select-pane -t "$SESSION:w0.0"          # focus orchestrator
  else
    record "$1" "$(split_idle "$1" "$SESSION:0" -h -p 50)"
    tmux rename-window -t "$SESSION:0" "orch·$1"; shift
    local win=1
    while [ "$#" -gt 0 ]; do
      local r1="$1" r2=""
      local wid; wid=$(tmux new-window -P -F '#{window_id}' -t "$SESSION" -c "$ws" "$(idle_cmd "$1")")
      record "$1" "$(tmux display -p -t "$wid" '#{pane_id}')"
      shift
      [ "$#" -gt 0 ] && { r2="$1"; record "$1" "$(split_idle "$1" "$wid" -h -p 50)"; shift; }
      tmux rename-window -t "$wid" "$r1${r2:+·$r2}"
      win=$((win+1))
    done
  fi

  ui_title "team launched"
  printf "  ${GREEN}✓${NC} attach   ${B}tmux attach -t %s${NC}\n" "$SESSION" >&2
  printf "  ${GRAY}·${NC} switch   ${DIM}Option+Tab${NC}   ${GRAY}·${NC} zoom ${DIM}Ctrl-b z${NC}   ${GRAY}·${NC} stop ${DIM}tools agents stop${NC}\n" >&2
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
  [ -n "$line" ] || die "role '$role' not found in PANES.md (is the team running?)"
  local pane harness model
  pane=$(echo "$line"    | sed -E 's/.*pane=([^ ]+).*/\1/')
  harness=$(echo "$line" | sed -E 's/.*harness=([^ ]+).*/\1/')
  model=$(echo "$line"   | sed -E 's/.*model=(.+)$/\1/')   # model is last; may contain spaces
  # ask the worker to end with a one-line summary so .done carries a real signal.
  local ftask="$task

When done, print a final line starting with SUMMARY: that states in <=15 words what you changed or found."
  local cmd; cmd=$(worker_cmd "$harness" "$model" "$ftask")
  rm -f "$out/$role.done" "$out/$role.out"
  # capture full output to <role>.out; write structured <role>.done:
  #   line1 = exit code   line2 = SUMMARY (the worker's summary line, or last line)
  # Orchestrator reads .done (tiny); opens .out only when it needs detail.
  local d="$out/$role.done" o="$out/$role.out"
  # run capture logic in bash explicitly (pane shell may be zsh; PIPESTATUS is bash).
  local cap="$cmd 2>&1 | tee $(shquote "$o"); ec=\${PIPESTATUS[0]}; { echo \$ec; (grep -m1 '^SUMMARY:' $(shquote "$o") || tail -n1 $(shquote "$o")) | sed 's/^SUMMARY: *//'; } > $(shquote "$d")"
  tmux send-keys -t "$pane" "bash -c $(shquote "$cap"); echo '[$role done -> .done]'" Enter

  # WATCHDOG: even with auto-approve flags, if a worker hangs (or a flag fails to
  # suppress a prompt) the .done would never appear and the orchestrator would wait
  # forever. Background watchdog: if .done is absent after DISPATCH_TIMEOUT, write a
  # failure sentinel so the orchestrator sees it failed and can re-dispatch/escalate.
  local to="${ARKESTRA_TIMEOUT:-600}"   # seconds; override via env
  ( e=$(( $(date +%s) + to ))
    while [ ! -f "$d" ] && [ "$(date +%s)" -lt "$e" ]; do sleep 3; done
    [ -f "$d" ] || printf '124\nTIMEOUT: no .done after %ss (worker hung or blocked on a prompt)\n' "$to" > "$d"
  ) >/dev/null 2>&1 &

  printf "${GREEN}dispatched${NC} %s -> %s  ${GRAY}(read .agent-out/%s.done; full in %s.out; timeout %ss)${NC}\n" \
    "$role" "$pane" "$role" "$role" "$to"
}

# =====================================================================
# `tools agents stop` — tear down the running team: kill the tmux session,
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
    # remove the fresh worktrees arkestra creates (.worktrees/agents-*) and their
    # throwaway agents/* branches.
    if [ -d "$repo/.worktrees" ]; then
      local wt
      for wt in "$repo"/.worktrees/agents-*; do
        [ -d "$wt" ] && git -C "$repo" worktree remove --force "$wt" 2>/dev/null
      done
      git -C "$repo" worktree prune 2>/dev/null
      rmdir "$repo/.worktrees" 2>/dev/null || true
    fi
    local br
    for br in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/agents 2>/dev/null); do
      git -C "$repo" branch -D "$br" 2>/dev/null
    done
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
  local def; def=$(default_harness "$role")
  ui_title "configure role" "$role"

  # 1) pick the harness — only installed ones, default marked.
  local hopts=""
  for h in $ALL_HARNESSES; do
    command -v "$h" >/dev/null 2>&1 || continue
    if [ "$h" = "$def" ]; then hopts="$hopts$h  (default)
"; else hopts="$hopts$h
"; fi
  done
  local harness; harness=$(ui_choose "harness (CLI) for $role:" "$hopts")
  harness="${harness%%  *}"                       # strip the "(default)" suffix
  [ -n "$harness" ] || harness="$def"             # empty pick = default

  # 2) pick a model from that harness; a "type custom" option allows any
  # callable id the CLI doesn't list.
  local models; models=$(list_models_for "$harness")
  local chosen
  if [ -n "$models" ]; then
    chosen=$(ui_choose "model for $harness:" "$models
✎ type a custom model id…")
    case "$chosen" in "✎ type a custom"*) chosen=$(ui_input "custom model id:") ;; esac
  else
    chosen=$(ui_input "$harness lists no models — type any callable id:")
  fi
  [ -n "$chosen" ] || die "nothing picked"

  conf_set "$role" "$harness" "$chosen"
  printf "\n  ${GREEN}✓${NC} ${B}%s${NC} ${GRAY}→${NC} ${CYAN}%s${NC} ${GRAY}·${NC} %s\n" "$role" "$harness" "$chosen" >&2
  printf "  ${DIM}saved to %s${NC}\n" "$CONF" >&2
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
  probe "$roles" || exit $?
  launch "$roles" "$repo" "$ws"
}

main "$@"
