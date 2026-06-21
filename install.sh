#!/usr/bin/env bash
#
# arkestra install - cross-platform dependency check/setup (macOS + Arch Linux).
#
# arkestra itself is a single POSIX-ish bash script; "install" means: confirm
# the runtime deps are present and offer to install the ones a package manager
# can provide. The agent CLIs (claude/codex/opencode/pi/gemini) are installed
# out-of-band (npm/curl per their own docs) -- we only check + point you at them.
#
# bash 3.2 safe (macOS default bash). No associative arrays, no `\s`, no GNU-isms.
set -eu

RED='\033[38;5;1m'; GREEN='\033[38;5;2m'; YELLOW='\033[38;5;3m'
BLUE='\033[38;5;4m'; GRAY='\033[38;5;8m'; NC='\033[0m'
ok()   { printf "  ${GREEN}ok${NC}    %s\n" "$*"; }
miss() { printf "  ${RED}miss${NC}  %s\n" "$*"; }
note() { printf "  ${YELLOW}note${NC}  %s\n" "$*"; }

# ---- detect platform + package manager ----
OS="$(uname -s)"
PM=""; PM_INSTALL=""
case "$OS" in
  Darwin)
    PLATFORM="macOS"
    if command -v brew >/dev/null 2>&1; then PM="brew"; PM_INSTALL="brew install"; fi ;;
  Linux)
    PLATFORM="Linux"
    if   command -v pacman >/dev/null 2>&1; then PM="pacman"; PM_INSTALL="sudo pacman -S --needed";
    elif command -v apt-get >/dev/null 2>&1; then PM="apt";    PM_INSTALL="sudo apt-get install -y";
    elif command -v dnf >/dev/null 2>&1;     then PM="dnf";    PM_INSTALL="sudo dnf install -y"; fi
    # is this Arch specifically?
    [ -f /etc/arch-release ] && PLATFORM="Arch Linux" ;;
  *) PLATFORM="$OS" ;;
esac

printf "${BLUE}arkestra install${NC}  platform: %s  package manager: %s\n\n" \
  "$PLATFORM" "${PM:-none found}"

# ---- system deps a package manager CAN provide ----
SYS_MISSING=""
for dep in tmux git; do
  if command -v "$dep" >/dev/null 2>&1; then
    case "$dep" in
      tmux) ver="$(tmux -V 2>/dev/null)" ;;
      *)    ver="$($dep --version 2>/dev/null | head -1)" ;;
    esac
    ok "$dep ($ver)"
  else miss "$dep"; SYS_MISSING="$SYS_MISSING $dep"; fi
done

# ---- agent CLIs: checked, not auto-installed (each has its own installer) ----
printf "\n${BLUE}agent CLIs${NC} (install via their own docs if missing):\n"
check_cli() {  # name  hint
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else miss "$1  ${GRAY}-> $2${NC}"; fi
}
check_cli claude   "https://docs.claude.com/claude-code  (orchestrator, REQUIRED)"
check_cli codex    "npm i -g @openai/codex  (arch role)"
check_cli opencode "https://opencode.ai  (coding role)"
check_cli pi       "pi CLI  (impl/git roles)"
check_cli gemini   "npm i -g @google/gemini-cli  (logs role)"

# ---- offer to install the system deps via the detected PM ----
if [ -n "$SYS_MISSING" ]; then
  printf "\n${YELLOW}missing system deps:${NC}%s\n" "$SYS_MISSING"
  if [ -n "$PM_INSTALL" ]; then
    printf "  install with: ${BLUE}%s%s${NC}\n" "$PM_INSTALL" "$SYS_MISSING"
    printf "  run it now? [y/N] "
    read -r ans || true
    case "$ans" in y|Y|yes) $PM_INSTALL $SYS_MISSING ;; *) note "skipped; install them yourself." ;; esac
  else
    case "$OS" in
      Darwin) note "no Homebrew found. Install it: https://brew.sh, then: brew install$SYS_MISSING" ;;
      *)      note "no supported package manager found; install$SYS_MISSING via your distro." ;;
    esac
  fi
else
  printf "\n${GREEN}all system deps present.${NC}\n"
fi

# ---- bash version note (macOS ships 3.2; the script is 3.2-safe) ----
bv="${BASH_VERSION:-unknown}"
case "$bv" in
  3.*) note "system bash is $bv (macOS default) - arkestra is written to run on it." ;;
esac

# ---- config dir ----
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arkestra"
mkdir -p "$CONF_DIR"
ok "config dir: $CONF_DIR"

printf "\n${GREEN}done.${NC} launch with ${BLUE}tools agents${NC}; set defaults with ${BLUE}tools agents set <role>${NC}\n"
