#!/usr/bin/env bash
#
# arkestra.sh - launch a tmux structure of CLI coding agents orchestrated by
# Claude (or Codex), coordinated via file sentinels. Invoked as `arkestra` / `ark`.
#
# Design (all pieces proven standalone before assembly):
#   - orchestrator = Claude (default) or Codex, always left half of window 0;
#     both get the SAME composed brief + roster (chosen at launch / --orch)
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

SESSION="arkestra"   # resolved per-launch to a unique <repo>-<name> (see resolve_session)
SESSION_PREFIX="arkestra"   # set per-run to the current repo's name (see set_prefix)
ORCH="claude"        # orchestrator CLI for pane 0; claude (default) or codex (see pick_orchestrator)
# INVOKE — the command users (and the orchestrator) type to drive arkestra:
# normally the invoked name (arkestra / ark). A wrapper that re-exposes arkestra
# under a different command can override it by exporting ARKESTRA_INVOKE. All help
# text, runtime hints, and the orchestrator brief render with this so
# self-references (e.g. `<INVOKE> dispatch ...`) match how this install is driven.
INVOKE="${ARKESTRA_INVOKE:-$(basename "$0" .sh)}"
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

# ui_input <prompt> [default]  -> free-text entry (gum input or read).
# the prompt text doubles as the placeholder; [default] pre-fills (Enter keeps it).
ui_input() {
  if [ "$HAS_GUM" = 1 ]; then
    gum input --prompt="  $1 " --value="${2:-}" --placeholder="${1%:}…" 2>/dev/tty
  else
    printf "  %s [%s] " "$1" "${2:-}" >&2; local v; read -r v || true; printf '%s' "${v:-${2:-}}"
  fi
}

# Persistent per-role model defaults (set once via `arkestra set <role>`).
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
# Format: <role> <harness> <model>   (set via `arkestra set <role>`).
EOF
  fi
  local tmp="$CONF.tmp"
  grep -v "^$1[[:space:]]" "$CONF" > "$tmp" 2>/dev/null || true
  echo "$1 $2 $3" >> "$tmp"
  mv "$tmp" "$CONF"
}

# set_prefix — scope session names to the current repo. tmux session names allow
# no '.'/':', so sanitize the basename; fall back to "arkestra" outside a repo.
set_prefix() {
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  local b; b=$(basename "$repo" | tr '.:' '__')
  [ -n "$b" ] && SESSION_PREFIX="$b"
}

# ---- running teams for this repo (tmux sessions named <repo>-*) ----
list_teams() { tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true ; }

# auto_name -> lowest free <repo>-<N>
auto_name() { local i=1; while tmux has-session -t "${SESSION_PREFIX}-$i" 2>/dev/null; do i=$((i+1)); done; echo "$i"; }

# resolve_session [name] -> echoes a UNIQUE session name. Given a name, uses
# <repo>-<name> (must be free). Otherwise prompts (default = next free number).
resolve_session() {
  local want="$1"
  if [ -z "$want" ]; then
    local def; def=$(auto_name)
    want=$(ui_input "team name:" "$def")        # Enter keeps the auto number
    [ -n "$want" ] || want="$def"
  fi
  local n="${SESSION_PREFIX}-${want}"
  tmux has-session -t "$n" 2>/dev/null && die "a team named '$n' is already running (stop it first, or pick another name)"
  echo "$n"
}

# pick_orchestrator [forced] -> echoes the orchestrator CLI for pane 0. claude is
# the default; codex is the alternative. A non-empty [forced] (from --orch) skips
# the prompt. The chosen CLI must exist on PATH (workers don't need the orch CLI).
pick_orchestrator() {
  local forced="${1:-}"
  if [ -n "$forced" ]; then
    case "$forced" in claude|codex) echo "$forced"; return ;;
      *) die "--orch must be claude or codex (got '$forced')" ;; esac
  fi
  local pick
  pick=$(ui_choose "who orchestrates? (Enter = claude)" "$(printf '● claude  (default)\n○ codex')")
  case "$pick" in *codex*) echo codex ;; *) echo claude ;; esac
}

usage() {
  # @ is the invocation placeholder; replaced with $INVOKE (arkestra / ark) so the
  # help matches how this install is actually driven.
  sed "s|@|$INVOKE|g" <<'EOF'
@ - launch an orchestrated CLI agents team in tmux

  @ [roles...] [--<role> model] ...

ROLES (fixed priority, give any subset; unused are skipped):
  arch    codex     architecture / second opinion
  coding  opencode  complex coding
  impl    pi        direct implementation
  logs    agy       deep log / investigation
  git     git ops via pi (small/fast)

OVERRIDE a role's model for this session (else the saved/CLI default):
  @ coding arch --coding opencode/claude-opus-4-8 --arch gpt-5.5

SET a persistent per-role default (picker lists the CLI's real models):
  @ set coding        # then pick from the list; saved to agents.conf

Model resolution per role: --flag  >  agents.conf  >  the CLI's own default.
Bare `@` probes DEFAULT roles (coding arch git) and confirms.
The orchestrator runs as pane 0; you attach to watch. At launch you pick who
orchestrates (claude default, or codex) — both get the same brief + roster
through that CLI's native instruction layer.

  --orch <claude|codex>  set the orchestrator without the prompt (default claude;
                         codex runs -a never -s workspace-write).
  --start    attach (or switch-client, if already in tmux) right after launch.

Run MULTIPLE teams at once (each is its own tmux session, named <repo>-<team>).
You're prompted for a team name at launch (Enter keeps the auto number); or pass
--name to skip it:
  @ --name api coding impl     # session <repo>-api
  @ arch logs                   # prompts; default <repo>-1, -2…

OTHER COMMANDS:
  @ sessions [name]           list running teams and attach to one
                                         (picks if several; switch-client in tmux).
  @ model <role> [<harness>] <model>
                                         swap a LIVE worker's model (next dispatch
                                         uses it; orchestrator keeps its context).
  @ dispatch <role> "<task>"  (the orchestrator delegates a task)
  @ wait <role>               (block until the role's .done; print
                                         exit code + summary. orchestrator's only
                                         move after dispatch — no polling.)
  @ stop [--all] [--keep-out] stop a team (picks which if several;
                                         --all stops every team). prunes worktrees.
  @ install                   check/install deps (macOS + Arch/Linux)
  @ uninstall                 remove arkestra's own files (config dir)
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
  reasonix) # default_model from doctor's redacted json (authoritative; resolves
            # flag>./reasonix.toml>~/.reasonix/config.toml itself). Field is a
            # provider NAME (what -model takes), e.g. deepseek-flash.
            reasonix doctor --json 2>/dev/null \
              | sed -E -n 's/.*"default_model"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1 ;;
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
  reasonix)  reasonix doctor --json 2>/dev/null \
               | sed -E -n 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | grep -qx "$m" ;;
  *)         command -v "$h" >/dev/null 2>&1 ;;                     # unknown harness: just exists
esac; }

# ---- per-HARNESS: the REAL model list from that CLI (one id per line) ----
# Sourced straight from each CLI; nothing invented.
list_models_for() { case "$1" in   # $1 = harness
  opencode)  opencode models 2>/dev/null ;;
  pi)        pi --list-models 2>/dev/null | sed -n '2,$p' | awk '{print $1"/"$2}' ;;
  codex)     pi --list-models 2>/dev/null | awk '/openai-codex/{print $2}' ;;  # gpt-5.x ids
  agy)       agy models 2>/dev/null ;;
  reasonix)  reasonix doctor --json 2>/dev/null \
               | sed -E -n 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' ;;  # provider names
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
    reasonix) # `run` executes one task and exits, already non-interactive and
              # auto-approving tools. Any GLOBAL flag before `run` (e.g.
              # --dangerously-skip-permissions / --yolo) instead launches the
              # interactive UI, so pass nothing but `run`.
              echo "reasonix run --model $m $t";;
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

# ---- run_banner: a styled header printed in the pane right before a dispatched
# task runs, so a human scanning panes instantly sees WHO is reasoning about WHAT.
# This is arkestra's own chrome (we own/style it); the worker's native output
# follows below it, in the CLI's own colors (preserved via the PTY wrapper). The
# task is truncated to one tidy line.
run_banner_for() {
  local role="$1" harness="$2" model="$3" task="$4"
  local t; t=$(printf '%s' "$task" | tr '\n' ' ' | cut -c1-72)
  printf '\033[38;5;8m╭─ \033[1;38;5;2m▶ %s\033[0;38;5;8m · \033[38;5;6m%s\033[38;5;8m · %s\n│  \033[38;5;7m%s\033[38;5;8m\n╰─\033[0m\n' \
    "$role" "$harness" "$model" "$t"
}

# ---- pty_wrap: emit a command that runs $1 (a shell command STRING) under a
# pseudo-TTY via script(1), teeing the raw typescript to $2. The PTY makes each
# CLI think it's interactive, so it keeps its native COLORS/formatting in the pane
# instead of falling back to the de-colored "piped" mode. script's flags differ by
# OS (BSD vs util-linux), so we branch. Exit code of the inner command propagates.
#   $1 = command string   $2 = raw-typescript file path (already shquoted by caller)
pty_wrap() {
  local cmd="$1" rawfile="$2"
  case "$(uname -s)" in
    Darwin|*BSD) echo "script -q $rawfile bash -c $(shquote "$cmd")" ;;   # BSD: file then command
    *)           echo "script -q -e -c $(shquote "$cmd") $rawfile" ;;     # util-linux: -e returns child code, -c command, file last
  esac
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
  local cur base label
  cur=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ -n "$cur" ]; then
    base="$cur"
    label="$cur"
  else
    base="HEAD"
    label="detached $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo HEAD)"
  fi
  ui_title "workspace" "all workers share one tree"

  # build menu: current branch first, then other branches, then "new worktree".
  # (use printf for newlines — embedded literal newlines in assignments are fragile
  # under set -u and can corrupt the var.) Hide arkestra's throwaway agents/* branches.
  local opts; opts=$(printf '● %s  (current)\n' "$label")
  local b
  for b in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null); do
    [ "$b" = "$cur" ] && continue
    case "$b" in agents/*) continue ;; esac
    opts=$(printf '%s\n○ %s' "$opts" "$b")
  done
  opts=$(printf '%s\n+ new worktree off %s' "$opts" "$label")

  local pick; pick=$(ui_choose "where should the team work?" "$opts")
  [ -n "$pick" ] || { echo "$repo"; return; }                # default = current
  case "$pick" in
    *"(current)") echo "$repo" ;;
    "+ new worktree"*)
        # a worktree needs its OWN branch — two worktrees can't share one (e.g.
        # 'master' is already checked out here). Branch a fresh one off $base.
        local wt="$repo/.worktrees/agents-$$" br="agents/$$"
        git -C "$repo" worktree add -q -b "$br" "$wt" "$base" >&2 \
          || die "worktree add failed"
        ui_ok "fresh worktree ${wt##*/} on branch $br (off $label)"; echo "$wt" ;;
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

# ensure arkestra's scratch paths are git-ignored in the repo (idempotent).
# Appends a guarded block to .gitignore; never clobbers existing content.
ensure_gitignore() {
  local repo="$1" gi="$1/.gitignore"
  grep -q '^# arkestra$' "$gi" 2>/dev/null && return 0   # block already present
  { [ -s "$gi" ] && printf '\n'
    printf '# arkestra\n.agent-out/\n.worktrees/\n'
  } >> "$gi"
}

# =====================================================================
# LAUNCH: build tmux structure; all workers run in the SHARED workspace.
# =====================================================================
launch() {
  local roles="$1" repo="$2" ws="$3"
  ensure_gitignore "$repo"
  local out="$ws/.agent-out"; mkdir -p "$out"
  : > "$out/PANES.md"   # role -> pane map the orchestrator reads to dispatch

  # ROSTER: the orchestrator must dispatch ONLY to roles actually on this team.
  # ORCHESTRATOR.md lists every possible role; the roster scopes it to what launched.
  # We compose the static brief + roster into ONE per-team file, fed to whichever
  # orchestrator launches (see below). One file avoids multiline shell-quoting,
  # and claude rejects mixing an inline prompt with the file flag.
  local src="$(cd "$(dirname "$0")" && pwd)/ORCHESTRATOR.md"
  local brief="$out/ORCHESTRATOR.md"
  # {{INVOKE}} in the brief -> the command this install answers to (arkestra / ark),
  # so the orchestrator dispatches via a command that exists here.
  [ -f "$src" ] && sed "s|{{INVOKE}}|$INVOKE|g" "$src" > "$brief" || : > "$brief"
  {
    printf '\nTHIS TEAM has exactly these roles — dispatch ONLY to them, never any other:\n'
    local rr rm rh
    for rr in $roles; do
      eval "rm=\${RESOLVED_$rr}"; eval "rh=\${RESOLVED_H_$rr}"
      printf '  - %s (%s · %s)\n' "$rr" "$rh" "$rm"
    done
    printf 'If a task needs a role not listed above, tell the user it is not on this team (do NOT dispatch it).\n'
  } >> "$brief"

  # Start pane 0 with the chosen orchestrator, both fed the SAME composed brief
  # (static ORCHESTRATOR.md + this team's roster) via each CLI's native
  # instruction surface. Claude has a system-prompt file flag. Codex runs in
  # auto mode (-a never) while staying workspace-sandboxed, and uses
  # invocation-scoped developer_instructions so the TUI stays idle for the
  # human's actual first task instead of arkestra's control brief.
  local orch_cmd
  case "$ORCH" in
    codex)  orch_cmd="codex -a never -s workspace-write -c developer_instructions=\"\$(cat $(shquote "$brief"))\"" ;;
    *)      orch_cmd="claude --append-system-prompt-file $(shquote "$brief")" ;;
  esac

  # SESSION is already a unique name (resolve_session); do NOT kill siblings.
  # Start the orchestrator as the pane command instead of typing it with
  # send-keys; this keeps the launch command out of visible scrollback.
  tmux new-session -d -s "$SESSION" -n w0 -c "$ws" "clear; $orch_cmd; exec $(shquote "${SHELL:-/bin/zsh}")"
  style_session                                       # modern status bar + pane borders

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
    tmux select-pane -t "$SESSION:0.0"           # focus orchestrator (by index; w0 renamed above)
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
  printf "  ${GRAY}·${NC} switch   ${DIM}Option+Tab${NC}   ${GRAY}·${NC} zoom ${DIM}Ctrl-b z${NC}   ${GRAY}·${NC} stop ${DIM}%s stop${NC}\n" "$INVOKE" >&2
}

# =====================================================================
# `arkestra dispatch <role> "<task>"` — the ORCHESTRATOR uses this to run a
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
  # GIT ROLE: the worker has no /commit slash-command, and the orchestrator must
  # NOT reason about messages/branches. So we bake the commit contract into the
  # task here: ONE commit per file/folder (NOT git add -A into one lump),
  # single-line conventional message, <=50 chars, NO body/description.
  local ftask="$task"
  if [ "$role" = git ]; then
    ftask="$task

COMMIT RULE (follow exactly; do NOT think, just apply):
- ONE commit per file OR per folder. NEVER lump everything into a single commit. Do NOT 'git add -A' then commit once.
- A folder may be one commit ONLY if every file in it is the exact same change (e.g. a rename); otherwise commit file by file.
- For each: stage just that file/folder (git add <path>) then commit it before staging the next.
- Message format: <type>(<scope>): <description>  — types: feat fix docs style ref test chore
- SINGLE LINE ONLY. No body, no description, no extra paragraphs. Max 50 chars total. Lowercase. No trailing period.
- Use: git commit -m \"<message>\"  (one -m only; never a second -m or a heredoc body)."
  fi
  # ask the worker to end with a one-line summary so .done carries a real signal.
  ftask="$ftask

When done, print a final line starting with SUMMARY: that states in <=15 words what you changed or found."
  local cmd; cmd=$(worker_cmd "$harness" "$model" "$ftask")
  rm -f "$out/$role.done" "$out/$role.out" "$out/$role.out.raw"
  # capture full output to <role>.out; write structured <role>.done:
  #   line1 = exit code   line2 = SUMMARY (the worker's summary line, or last line)
  # Orchestrator reads .done (tiny); opens .out only when it needs detail.
  local d="$out/$role.done" o="$out/$role.out" oraw="$out/$role.out.raw"
  # Show arkestra's styled header in the pane, then run the worker UNDER A PTY
  # (pty_wrap → script) so the CLI keeps its NATIVE COLORS live in the pane. script
  # tees a raw typescript to $oraw AND echoes it to the pane (its normal behavior).
  # After the worker exits we de-ANSI/de-CR $oraw → $o so the orchestrator (and the
  # SUMMARY grep) read CLEAN text, while the human keeps full color in the pane.
  run_banner_for "$role" "$harness" "$model" "$task" > "$out/.runhdr-$role"
  local wrapped; wrapped=$(pty_wrap "$cmd 2>&1" "$(shquote "$oraw")")
  # run capture logic in bash explicitly (pane shell may be zsh; PIPESTATUS is bash).
  # ESC built at runtime: BSD sed has no \x1b. Guard: if the watchdog already wrote a
  # 124 (stall/cap), a late-finishing worker must NOT clobber it — first writer wins.
  # Strip, in order: CSI color/cursor escapes; carriage returns; backspace/EOT
  # bytes; and BSD script's leading literal "^D" session marker. Leaves clean text.
  local cap="ESC=\$(printf '\\033'); $wrapped; ec=\$?; \
sed -E \"s/\${ESC}\\[[0-9;]*[a-zA-Z]//g; s/\$(printf '\\r')//g; s/[\$(printf '\\010\\004')]//g; 1s/^\\^D//\" $(shquote "$oraw") > $(shquote "$o") 2>/dev/null; \
[ -f $(shquote "$d") ] || { echo \$ec; (grep -m1 '^SUMMARY:' $(shquote "$o") || tail -n1 $(shquote "$o")) | sed 's/^SUMMARY: *//'; } > $(shquote "$d")"
  tmux send-keys -t "$pane" "clear; cat $(shquote "$out/.runhdr-$role"); bash -c $(shquote "$cap"); echo '[$role done -> .done]'" Enter

  # WATCHDOG: even with auto-approve flags, a worker can hang (a prompt the flag
  # failed to suppress, a deadlock, a stuck network call) — then .done never appears
  # and the orchestrator waits forever. Two complementary triggers, whichever hits
  # first writes a 124 sentinel so `wait` returns and the orchestrator can escalate:
  #   STALL — the live typescript (.out.raw, written by script during the run)
  #           stopped growing for ARKESTRA_STALL seconds. A live worker streams
  #           narration/diffs, so a silent raw file == stuck. This catches a hang
  #           FAST (default 90s) without waiting out the full hard cap, and without
  #           false-positives on a slow-but-working task (it keeps emitting). NB: we
  #           watch .out.raw (grows live), not .out (written only after exit).
  #   HARD  — wall-clock cap (ARKESTRA_TIMEOUT), but PROGRESS-AWARE: it is a
  #           backstop for a worker still dribbling output past the cap, NOT a
  #           guillotine for a healthy verbose one. Past the cap we additionally
  #           require recent silence (>= stall/2) before firing, so a worker that
  #           keeps streaming narration/diffs is never killed mid-task — only one
  #           that has both blown the cap AND gone quiet (the real "wedged" shape).
  #           Set ARKESTRA_HARD_STRICT=1 to restore the old absolute guillotine.
  local hard="${ARKESTRA_TIMEOUT:-300}"   # seconds, wall-clock cap; env-overridable
  local stall="${ARKESTRA_STALL:-90}"     # seconds of no .out growth = hung
  local hard_quiet=$(( stall / 2 )); [ "$hard_quiet" -ge 1 ] || hard_quiet=1
  ( deadline=$(( $(date +%s) + hard ))
    last_sz=-1; last_change=$(date +%s); fired=0
    while [ ! -f "$d" ]; do
      now=$(date +%s)
      sz=$(wc -c < "$oraw" 2>/dev/null | tr -d ' '); sz="${sz:-0}"
      if [ "$sz" != "$last_sz" ]; then last_sz="$sz"; last_change="$now"; fi
      quiet=$(( now - last_change ))
      if [ "$quiet" -ge "$stall" ]; then
        [ -f "$d" ] || printf '124\nSTALL: no output for %ss (worker hung or blocked on a prompt)\n' "$stall" > "$d"
        fired=1; break
      fi
      # Past the cap: fire only if also quiet (wedged), unless STRICT forces the
      # old absolute behavior. A still-streaming worker sails past the cap freely.
      if [ "$now" -ge "$deadline" ] && { [ "${ARKESTRA_HARD_STRICT:-0}" = 1 ] || [ "$quiet" -ge "$hard_quiet" ]; }; then
        [ -f "$d" ] || printf '124\nTIMEOUT: exceeded %ss cap and quiet %ss (worker wedged)\n' "$hard" "$quiet" > "$d"
        fired=1; break
      fi
      sleep 3
    done
    # If WE declared the hang (not a clean finish), reclaim the pane: SIGINT the
    # stuck process so the pane's shell survives and returns to its idle banner —
    # otherwise a zombie worker would eat the next dispatch's keystrokes. The 124
    # sentinel is already written (first-writer guard), so a worker that was a
    # hair from finishing loses nothing. Escalate to respawn only if C-c doesn't
    # land the pane back at idle within a couple seconds.
    if [ "$fired" = 1 ]; then
      tmux send-keys -t "$pane" C-c 2>/dev/null || true
      sleep 2
      # is the pane back at its shell? pane_current_command is the foreground proc.
      cur=$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
      case "$cur" in
        bash|zsh|sh|-bash|-zsh|"") : ;;   # idle shell -> reusable, leave it
        *)  # still wedged in a non-shell command -> hard reclaim: respawn the pane
            # to a fresh idle shell that re-shows the role's banner (same as launch).
            banner="$out/.banner-$role"
            tmux respawn-pane -k -t "$pane" \
              "clear; cat $(shquote "$banner") 2>/dev/null; exec ${SHELL:-/bin/zsh}" 2>/dev/null || true ;;
      esac
    fi
  ) >/dev/null 2>&1 &

  printf "${GREEN}dispatched${NC} %s -> %s  ${GRAY}(then: %s wait %s; stall %ss, cap %ss progress-aware)${NC}\n" \
    "$role" "$pane" "$INVOKE" "$role" "$stall" "$hard"
}

# =====================================================================
# `arkestra wait <role>` — BLOCK until the role's .done exists, then print
# its two lines and exit with the worker's own exit code. This is the
# orchestrator's ONE move after dispatch: a single blocking call instead of a
# poll loop in Claude's context (which burns tokens re-reading state). The
# dispatch watchdog guarantees a .done appears within the timeout, so this can
# never hang forever. Output is deliberately tiny and fixed-format.
#   exit 0  -> success   nonzero -> the worker failed   124 -> timed out/hung
# =====================================================================
cmd_wait() {
  local role="${1:-}"
  [ -n "$role" ] || die "wait <role>"
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repo"
  local d="$repo/.agent-out/$role.done"
  # PANES.md confirms the role is on this team; otherwise there's nothing to wait on.
  awk -v r="$role" '$1==r{f=1} END{exit !f}' "$repo/.agent-out/PANES.md" 2>/dev/null \
    || die "role '$role' not on the running team (no $role line in PANES.md)"
  # Block in this subprocess — NOT in the orchestrator's context. The watchdog
  # writes a 124 sentinel if the worker hangs, so this loop is bounded.
  while [ ! -f "$d" ]; do sleep 2; done
  local ec sum
  ec=$(sed -n '1p' "$d"); sum=$(sed -n '2p' "$d")
  case "$ec" in
    0)   printf "${GREEN}✓ %s done${NC}  %s\n" "$role" "$sum" ;;
    124) printf "${RED}✗ %s TIMED OUT/HUNG${NC}  %s\n" "$role" "$sum" >&2
         printf "  ${YELLOW}↳ HALT: do NOT do this work yourself. Report it; inspect .agent-out/%s.out only if needed.${NC}\n" "$role" >&2 ;;
    *)   printf "${RED}✗ %s FAILED (exit %s)${NC}  %s\n" "$role" "$ec" "$sum" >&2
         printf "  ${YELLOW}↳ HALT: do NOT do this work yourself. Report it; inspect .agent-out/%s.out only if needed.${NC}\n" "$role" >&2 ;;
  esac
  # exit code mirrors the worker so a caller (or the orchestrator) can branch on it.
  [ "$ec" = 0 ] && return 0 || return "${ec:-1}"
}

# =====================================================================
# `arkestra model <role> [<harness>] <model>` — change a LIVE team's worker
# model without restarting. Workers are stateless per-dispatch (dispatch reads
# harness/model from PANES.md each time), so rewriting PANES.md is enough — the
# orchestrator (pane 0) keeps all its context. Refreshes the worker's banner too.
# =====================================================================
cmd_model() {
  local role="${1:-}" a2="${2:-}" a3="${3:-}"
  [ -n "$role" ] && [ -n "$a2" ] || die "model <role> [<harness>] <model>  (e.g. model coding opencode/claude-opus-4-8)"
  local repo; repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repo"
  local panes="$repo/.agent-out/PANES.md"
  local line; line=$(awk -v r="$role" '$1==r{print; exit}' "$panes" 2>/dev/null)
  [ -n "$line" ] || die "role '$role' not on the running team (no $role line in PANES.md)"

  # arg shapes: `model coding opencode/gpt-5.5`  OR  `model coding opencode gpt-5.5`.
  local harness model pane
  pane=$(printf '%s' "$line" | sed -E 's/.*pane=([^ ]+).*/\1/')
  if [ -n "$a3" ]; then harness="$a2"; model="$a3"
  else harness=$(printf '%s' "$line" | sed -E 's/.*harness=([^ ]+).*/\1/'); model="$a2"; fi

  valid_for "$harness" "$model" || printf "  ${YELLOW}!${NC} ${DIM}%s may not list '%s' — dispatching anyway${NC}\n" "$harness" "$model" >&2

  # rewrite ONLY this role's line, preserving column layout dispatch parses.
  local tmp; tmp=$(mktemp)
  awk -v r="$role" -v p="$pane" -v h="$harness" -v m="$model" \
    '$1==r{printf "%-7s pane=%s  harness=%s  model=%s\n",$1,p,h,m;next}1' \
    "$panes" > "$tmp" && mv "$tmp" "$panes"

  # refresh the idle banner so the pane shows the new model (cosmetic but honest).
  local out="$repo/.agent-out"
  banner_for "$role" "$harness" "$model" > "$out/.banner-$role"
  tmux send-keys -t "$pane" "clear; cat $(shquote "$out/.banner-$role")" Enter 2>/dev/null || true

  printf "  ${GREEN}✓${NC} ${B}%s${NC} ${GRAY}→${NC} ${CYAN}%s${NC} ${GRAY}·${NC} %s  ${DIM}(next dispatch uses it; orchestrator context kept)${NC}\n" \
    "$role" "$harness" "$model" >&2
}

# =====================================================================
# `arkestra stop` — tear down the running team: kill the tmux session,
# prune any worktrees it created, and clear .agent-out scratch (with --keep-out
# to leave sentinels/PANES.md for inspection).
# =====================================================================
cmd_stop() {
  local keep_out=0 all=0
  while [ "$#" -gt 0 ]; do case "$1" in
    --keep-out) keep_out=1 ;; --all) all=1 ;;
  esac; shift; done

  local teams; teams=$(list_teams)
  if [ -z "$teams" ]; then printf "  ${GRAY}no running teams.${NC}\n" >&2; return 0; fi

  local targets
  if [ "$all" = 1 ]; then
    targets="$teams"
  elif [ "$(printf '%s\n' "$teams" | grep -c .)" = 1 ]; then
    targets="$teams"                                   # only one running
  else
    ui_title "stop team" "$(printf '%s' "$teams" | tr '\n' ' ')"
    targets=$(ui_choose "which team to stop? (or --all)" "$teams")
    [ -n "$targets" ] || { printf "  ${DIM}cancelled.${NC}\n" >&2; return 0; }
  fi

  local t
  for t in $targets; do
    tmux kill-session -t "$t" 2>/dev/null && printf "  ${GREEN}✓${NC} stopped ${B}%s${NC}\n" "$t" >&2
  done

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

# =====================================================================
# `arkestra sessions` — list running teams and attach to a chosen one.
# Inside an existing tmux client we switch-client (attach refuses to nest);
# from a plain shell, attach. Pass a name to skip the picker.
# =====================================================================
cmd_sessions() {
  local want="${1:-}"
  local teams; teams=$(list_teams)
  if [ -z "$teams" ]; then printf "  ${GRAY}no running teams.${NC}\n" >&2; return 0; fi

  local target=""
  if [ -n "$want" ]; then
    case "$want" in ${SESSION_PREFIX}-*) target="$want" ;; *) target="${SESSION_PREFIX}-${want}" ;; esac
    tmux has-session -t "$target" 2>/dev/null || die "no running team '$target'"
  elif [ "$(printf '%s\n' "$teams" | grep -c .)" = 1 ]; then
    target="$teams"                                    # only one running
  else
    ui_title "running teams"
    local t
    for t in $teams; do
      local win; win=$(tmux list-windows -t "$t" -F '#{window_name}' 2>/dev/null | head -1)
      ui_kv "$t" "$win"
    done
    target=$(ui_choose "attach to which team?" "$teams")
    [ -n "$target" ] || { printf "  ${DIM}cancelled.${NC}\n" >&2; return 0; }
  fi

  if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$target"
  else exec tmux attach -t "$target"; fi
}

ALL_HARNESSES="codex opencode pi agy reasonix"   # claude excluded (it is the orchestrator)

# =====================================================================
# `arkestra set <role>` — pick HARNESS, then a model from it; save to conf.
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
  set_prefix   # scope session names to the current repo (before any subcommand)
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    set) shift; cmd_set "$@"; exit 0 ;;
    dispatch) shift; cmd_dispatch "$@"; exit 0 ;;
    wait) shift; cmd_wait "$@" && exit 0; exit $? ;;
    model) shift; cmd_model "$@"; exit 0 ;;
    stop) shift; cmd_stop "$@"; exit 0 ;;
    sessions|ls|attach) shift; cmd_sessions "$@"; exit 0 ;;
    install) exec bash "$(cd "$(dirname "$0")" && pwd)/install.sh" ;;
    uninstall) exec bash "$(cd "$(dirname "$0")" && pwd)/install.sh" --uninstall ;;
  esac
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  git rev-parse --git-dir >/dev/null 2>&1 || die "run inside a git repository"
  local repo; repo=$(git rev-parse --show-toplevel)

  # parse: positional roles + --<role> model overrides + --name <team> + --orch <cli>
  local want="" name="" start=0 orch=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) shift; [ "$#" -gt 0 ] || die "--name needs a value"; name="$1" ;;
      --orch) shift; [ "$#" -gt 0 ] || die "--orch needs a value (claude|codex)"; orch="$1" ;;
      --start) start=1 ;;
      --arch|--coding|--impl|--logs|--git)
        local rr="${1#--}"; shift; [ "$#" -gt 0 ] || die "--$rr needs a model"
        eval "OVR_$rr=\"\$1\""; want="$want $rr" ;;
      arch|coding|impl|logs|git) want="$want $1" ;;
      *) die "unknown arg '$1' (try: $INVOKE --help)" ;;
    esac
    shift
  done
  [ -n "$want" ] || want="coding arch git"   # bare default set

  local roles; roles=$(order_roles $want)
  [ -n "$roles" ] || die "no valid roles"

  SESSION=$(resolve_session "$name")         # unique <repo>-<name|N>; no collision
  ORCH=$(pick_orchestrator "$orch")          # claude (default) or codex for pane 0
  command -v "$ORCH" >/dev/null 2>&1 || die "$ORCH (orchestrator) is required"
  local ws; ws=$(pick_workspace "$repo") || exit $?
  probe "$roles" || exit $?
  launch "$roles" "$repo" "$ws"

  # --start: jump straight into the team. Inside an existing tmux client we must
  # switch-client (attach refuses to nest); from a plain shell, attach.
  if [ "$start" -eq 1 ]; then
    if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$SESSION"
    else exec tmux attach -t "$SESSION"; fi
  fi
}

main "$@"
