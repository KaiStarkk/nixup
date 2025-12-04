#!/usr/bin/env bash
# core.sh - Colors, print functions, configuration, and lock management

# =============================================================================
# Colors - only use if outputting to a terminal (use tput for Nix compatibility)
# =============================================================================

if [ -t 1 ]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  NC=$(tput sgr0)
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  NC=""
fi

print_error() { echo "${RED}error:${NC} $1" >&2; }
print_success() { echo "${GREEN}✓${NC} $1"; }
print_info() { echo "${BLUE}info:${NC} $1"; }
print_warn() { echo "${YELLOW}warn:${NC} $1"; }

# =============================================================================
# Configuration
# =============================================================================

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nixup"
CACHE_MAX_AGE=${NIX_UPDATE_CACHE_AGE:-21600}
NIXPKGS_REF=${NIX_UPDATE_NIXPKGS_REF:-"github:nixos/nixpkgs/nixos-unstable"}
SYSTEM_PATH=${NIX_UPDATE_SYSTEM_PATH:-"/run/current-system"}
CONFIG_DIR="${NIXUP_CONFIG_DIR:-$HOME/code/github.com/KaiStarkk/nixos-config}"
BACKUP_DIR="$HOME/.config-backups"
MIN_NAME_LENGTH=${NIX_UPDATE_MIN_NAME_LENGTH:-3}

DEFAULT_EXCLUDE="glibc*|gcc-*|binutils*|linux-headers*|stdenv*"
DEFAULT_EXCLUDE+="|bootstrap-*|expand-response-params|audit-*"
DEFAULT_EXCLUDE+="|patchelf*|update-autotools*|move-*|patch-shebangs*"
DEFAULT_EXCLUDE+="|wrap-*|make-*-wrapper*|multiple-outputs*"
DEFAULT_EXCLUDE+="|pkg-config-wrapper*|strip*|compress-*|fixup-*"
DEFAULT_EXCLUDE+="|prune-*|reproducible-*|nix-support*|propagated-*"
DEFAULT_EXCLUDE+="|setup-hooks*|acl-*|attr-*|bzip2-*|xz-*|zlib-*|zstd-*"
DEFAULT_EXCLUDE+="|openssl-*|libffi-*|ncurses-*|readline-*"
DEFAULT_EXCLUDE+="|*-lib|*-dev|*-doc|*-man|*-info|*-debug|*-hook"
EXCLUDE_PATTERNS=${NIX_UPDATE_EXCLUDE:-"$DEFAULT_EXCLUDE"}

DEFAULT_VERSION_SUFFIXES="lib|bin|dev|out|doc|man|info|debug|terminfo|py|nc|pam|data|npm-deps|only-plugins-qml|fish-completions"
VERSION_SUFFIXES=${NIX_UPDATE_VERSION_SUFFIXES:-"$DEFAULT_VERSION_SUFFIXES"}

UPDATES_CACHE="$CACHE_DIR/updates.json"
INSTALLED_CACHE="$CACHE_DIR/installed.json"
NIXPKGS_CACHE="$CACHE_DIR/nixpkgs-versions.json"
STATUS_FILE="$CACHE_DIR/status.json"
LOCK_FILE="$CACHE_DIR/nixup.lock"
MODE_FILE="$CACHE_DIR/filter-mode"

# Filter modes for updates display
# 0 = Packages (only explicit packages from config)
# 1 = +Programs (packages + programs.*.enable)
# 2 = All (ex. system) (current behavior with exclusions)
# 3 = All (verbose) (everything, no exclusions)
FILTER_MODE_NAMES=("Packages" "+Programs" "All (ex. system)" "All (verbose)")
FILTER_MODE_COUNT=4

mkdir -p "$CACHE_DIR"

# =============================================================================
# Terminal dimensions
# =============================================================================

TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
BAR_WIDTH=$((TERM_WIDTH - 45))
[[ $BAR_WIDTH -lt 20 ]] && BAR_WIDTH=20

# =============================================================================
# Lock file management - prevent duplicate instances
# =============================================================================

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 1  # Another instance is running
    fi
    # Stale lock file, remove it
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
  return 0
}

check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0  # Another instance is running
    fi
  fi
  return 1  # No instance running
}

# =============================================================================
# Filter mode management
# =============================================================================

get_filter_mode() {
  if [[ -f "$MODE_FILE" ]]; then
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "0")
    # Validate mode is within range
    if [[ "$mode" =~ ^[0-9]+$ ]] && [[ "$mode" -lt "$FILTER_MODE_COUNT" ]]; then
      echo "$mode"
      return
    fi
  fi
  echo "0"
}

set_filter_mode() {
  local mode="$1"
  echo "$mode" > "$MODE_FILE"
}

get_filter_mode_name() {
  local mode="${1:-$(get_filter_mode)}"
  echo "${FILTER_MODE_NAMES[$mode]}"
}

cycle_filter_mode() {
  local direction="${1:-up}"
  local current
  current=$(get_filter_mode)
  local new_mode

  if [[ "$direction" == "up" ]]; then
    new_mode=$(( (current + 1) % FILTER_MODE_COUNT ))
  else
    new_mode=$(( (current - 1 + FILTER_MODE_COUNT) % FILTER_MODE_COUNT ))
  fi

  set_filter_mode "$new_mode"
  echo "$new_mode"
}
