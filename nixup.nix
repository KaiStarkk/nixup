{
  writeShellApplication,
  jq,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  moreutils,
  ncurses,
  alejandra,
  nix,
  diffutils,
  findutils,
}:
let
  dotfilesSetupDoc = builtins.readFile ./dotfiles-setup.txt;
in
writeShellApplication {
  name = "nixup";
  runtimeInputs = [
    jq
    coreutils
    gnugrep
    gawk
    gnused
    moreutils
    ncurses
    alejandra
    nix
    diffutils
    findutils
  ];
  text = ''
    set -euo pipefail

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

    print_error() { echo "''${RED}error:''${NC} $1" >&2; }
    print_success() { echo "''${GREEN}✓''${NC} $1"; }
    print_info() { echo "''${BLUE}info:''${NC} $1"; }
    print_warn() { echo "''${YELLOW}warn:''${NC} $1"; }

    # =============================================================================
    # Configuration
    # =============================================================================

    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/nixup"
    CACHE_MAX_AGE=''${NIX_UPDATE_CACHE_AGE:-21600}
    NIXPKGS_REF=''${NIX_UPDATE_NIXPKGS_REF:-"github:nixos/nixpkgs/nixos-unstable"}
    SYSTEM_PATH=''${NIX_UPDATE_SYSTEM_PATH:-"/run/current-system"}
    CONFIG_DIR="''${NIXUP_CONFIG_DIR:-$HOME/code/nixos-config}"
    BACKUP_DIR="$HOME/.config-backups"
    MIN_NAME_LENGTH=''${NIX_UPDATE_MIN_NAME_LENGTH:-3}

    DEFAULT_EXCLUDE="glibc*|gcc-*|binutils*|linux-headers*|stdenv*"
    DEFAULT_EXCLUDE+="|bootstrap-*|expand-response-params|audit-*"
    DEFAULT_EXCLUDE+="|patchelf*|update-autotools*|move-*|patch-shebangs*"
    DEFAULT_EXCLUDE+="|wrap-*|make-*-wrapper*|multiple-outputs*"
    DEFAULT_EXCLUDE+="|pkg-config-wrapper*|strip*|compress-*|fixup-*"
    DEFAULT_EXCLUDE+="|prune-*|reproducible-*|nix-support*|propagated-*"
    DEFAULT_EXCLUDE+="|setup-hooks*|acl-*|attr-*|bzip2-*|xz-*|zlib-*|zstd-*"
    DEFAULT_EXCLUDE+="|openssl-*|libffi-*|ncurses-*|readline-*"
    DEFAULT_EXCLUDE+="|*-lib|*-dev|*-doc|*-man|*-info|*-debug|*-hook"
    EXCLUDE_PATTERNS=''${NIX_UPDATE_EXCLUDE:-"$DEFAULT_EXCLUDE"}

    DEFAULT_VERSION_SUFFIXES="lib|bin|dev|out|doc|man|info|debug|terminfo|py|nc|pam|data|npm-deps|only-plugins-qml|fish-completions"
    VERSION_SUFFIXES=''${NIX_UPDATE_VERSION_SUFFIXES:-"$DEFAULT_VERSION_SUFFIXES"}

    UPDATES_CACHE="$CACHE_DIR/updates.json"
    INSTALLED_CACHE="$CACHE_DIR/installed.json"
    NIXPKGS_CACHE="$CACHE_DIR/nixpkgs-versions.json"
    STATUS_FILE="$CACHE_DIR/status.json"
    LOCK_FILE="$CACHE_DIR/nixup.lock"

    mkdir -p "$CACHE_DIR"

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

    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    BAR_WIDTH=$((TERM_WIDTH - 45))
    [[ $BAR_WIDTH -lt 20 ]] && BAR_WIDTH=20

    # =============================================================================
    # Help
    # =============================================================================

    usage() {
      cat <<EOF
''${BOLD}nixup''${NC} - NixOS Management Tool

''${BOLD}USAGE:''${NC}
    nixup <subcommand> [options...]

''${BOLD}SUBCOMMANDS:''${NC}

  ''${CYAN}updates''${NC} - Package update checking
    count             Output just the update count (shows ? during refresh)
    tooltip           Get formatted tooltip text for status bars
    status            Get detailed status JSON
    fetch             Force refresh of package data
    list              Show available updates
    open              Open terminal with update list (for left-click)

  ''${CYAN}config''${NC} - Configuration management
    list [hook]       List all hooks or items in a hook
    add <hook> <item> Add item to a config hook
    rm <hook> <item>  Remove item from a config hook
    search <query>    Search nixpkgs for a package
    init <file> <hook> Initialize a new hook point
    format            Format all .nix files

  ''${CYAN}diff''${NC} - Dotfile backup management
    list              List all backed up dotfiles
    restore <file>    Restore a backed up dotfile
    clear             Remove all backups

  ''${CYAN}dotfiles''${NC} - Dotfile configuration help
    setup             Show how to set up managed dotfiles

''${BOLD}EXAMPLES:''${NC}
    nixup updates count
    nixup updates tooltip
    nixup config add packages ghq
    nixup config list packages
    nixup diff list

''${BOLD}ENVIRONMENT:''${NC}
    NIXUP_CONFIG_DIR     Config directory (default: ~/code/nixos-config)
    NIX_UPDATE_CACHE_AGE Cache validity (default: 21600s = 6h)
EOF
    }

    # =============================================================================
    # Progress bar
    # =============================================================================

    draw_progress() {
      local current="$1"
      local total="$2"
      local updates="$3"
      local percent=$((current * 100 / total))
      local filled=$((current * BAR_WIDTH / total))
      local empty=$((BAR_WIDTH - filled))

      local bar=""
      for ((i=0; i<filled; i++)); do bar+="█"; done
      for ((i=0; i<empty; i++)); do bar+="░"; done

      printf "\r  [%s] %3d%% (%d/%d) %d updates" "$bar" "$percent" "$current" "$total" "$updates" >&2
    }

    clear_progress() {
      printf "\r%*s\r" "$TERM_WIDTH" "" >&2
    }

    # =============================================================================
    # Status tracking (for status bars and frontends)
    # =============================================================================

    # Generate progress bar using block characters
    make_progress_bar() {
      local current="$1"
      local total="$2"
      local width="''${3:-10}"

      if [[ "$total" -eq 0 ]]; then
        printf '%*s' "$width" "" | tr ' ' '░'
        return
      fi

      local filled=$((current * width / total))
      local empty=$((width - filled))

      local bar=""
      for ((i=0; i<filled; i++)); do bar+="█"; done
      for ((i=0; i<empty; i++)); do bar+="░"; done
      echo "$bar"
    }

    write_status() {
      local status="$1"
      local message="$2"
      local progress="''${3:-0}"
      local total="''${4:-0}"

      local progress_bar=""
      if [[ "$total" -gt 0 ]]; then
        progress_bar=$(make_progress_bar "$progress" "$total" 10)
      fi

      jq -n \
        --arg status "$status" \
        --arg message "$message" \
        --argjson progress "$progress" \
        --argjson total "$total" \
        --arg progress_bar "$progress_bar" \
        --arg timestamp "$(date -Iseconds)" \
        '{
          status: $status,
          message: $message,
          progress: $progress,
          total: $total,
          progress_bar: $progress_bar,
          timestamp: $timestamp
        }' > "$STATUS_FILE"
    }

    get_status() {
      if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
      else
        echo '{"status":"idle","message":"Ready","progress":0,"total":0,"progress_bar":""}'
      fi
    }

    clear_status() {
      rm -f "$STATUS_FILE"
    }

    # Generate tooltip text for status bar integration
    get_tooltip() {
      local max_items=5

      if check_lock; then
        # Currently refreshing
        local status_json
        status_json=$(get_status)
        local message progress total progress_bar
        message=$(echo "$status_json" | jq -r '.message')
        progress=$(echo "$status_json" | jq -r '.progress')
        total=$(echo "$status_json" | jq -r '.total')
        progress_bar=$(echo "$status_json" | jq -r '.progress_bar // ""')

        echo "# refreshing"
        if [[ -n "$progress_bar" && "$total" -gt 0 ]]; then
          echo "$progress_bar ($progress/$total)"
        else
          echo "$message"
        fi
        return
      fi

      if [[ ! -f "$UPDATES_CACHE" ]]; then
        echo "# no data"
        echo "Run: nixup updates fetch"
        return
      fi

      local count
      count=$(jq -r '.count' "$UPDATES_CACHE")

      if [[ "$count" -eq 0 ]]; then
        echo "# up to date"
        return
      fi

      echo "# updates available"

      local shown=0
      while IFS= read -r line; do
        echo "- $line"
        ((shown++)) || true
      done < <(jq -r '.updates[:'"$max_items"'] | .[] | "\(.name) \(.installed) → \(.latest)"' "$UPDATES_CACHE")

      local remaining=$((count - shown))
      if [[ $remaining -gt 0 ]]; then
        echo "... and $remaining others"
      fi
    }

    # =============================================================================
    # Package parsing
    # =============================================================================

    parse_store_path() {
      local path="$1"
      local basename
      basename=$(basename "$path")
      local name_version="''${basename:33}"

      if [[ "$name_version" =~ ^(.+)-([0-9][0-9._a-zA-Z-]*)$ ]]; then
        local name="''${BASH_REMATCH[1]}"
        local version="''${BASH_REMATCH[2]}"
        version=$(echo "$version" | sed -E "s/[_-]($VERSION_SUFFIXES)\$//")
        local version_len=''${#version}
        if [[ "$version" =~ ^[0-9]+$ && $version_len -le 2 ]]; then
          if [[ ! "$name" =~ [0-9]$ ]]; then
            echo "$name_version|"
            return
          fi
        fi
        echo "$name|$version"
      else
        echo "$name_version|"
      fi
    }

    is_excluded() {
      local name="$1"
      eval "case \"\$name\" in $EXCLUDE_PATTERNS) return 0 ;; esac"
      return 1
    }

    # =============================================================================
    # Nixpkgs index
    # =============================================================================

    fetch_nixpkgs_index() {
      local force="''${1:-false}"

      if [[ "$force" != "true" && -f "$NIXPKGS_CACHE" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$NIXPKGS_CACHE")))
        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
          return 0
        fi
      fi

      echo "Fetching nixpkgs package index..." >&2
      write_status "running" "Fetching nixpkgs package index"
      nix search "$NIXPKGS_REF" "" --json 2>/dev/null | \
        jq 'to_entries
          | map({
              key: (.key | split(".") | last),
              value: .value.version,
              depth: (.key | split(".") | length)
            })
          | group_by(.key)
          | map(sort_by(.depth) | first | {key: .key, value: .value})
          | from_entries' | \
        sponge "$NIXPKGS_CACHE"

      local count
      count=$(jq 'length' "$NIXPKGS_CACHE")
      echo "Indexed $count packages." >&2
    }

    get_latest_version() {
      local pkg_name="$1"
      jq -r --arg name "$pkg_name" '.[$name] // empty' "$NIXPKGS_CACHE"
    }

    # =============================================================================
    # Installed packages
    # =============================================================================

    scan_installed_packages() {
      local installed=()

      while IFS= read -r path; do
        local parsed
        parsed=$(parse_store_path "$path")
        local name="''${parsed%%|*}"
        local version="''${parsed##*|}"

        [[ -z "$version" ]] && continue
        is_excluded "$name" && continue
        [[ ''${#name} -lt $MIN_NAME_LENGTH ]] && continue

        installed+=("{\"name\":\"$name\",\"version\":\"$version\"}")
      done < <(nix path-info -r "$SYSTEM_PATH" 2>/dev/null | sort -u)

      printf '%s\n' "''${installed[@]}" | \
        jq -s 'group_by(.name) | map(.[0]) | sort_by(.name)'
    }

    get_installed_packages() {
      local force_rescan="''${1:-false}"

      if [[ "$force_rescan" != "true" && -f "$INSTALLED_CACHE" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$INSTALLED_CACHE")))
        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
          cat "$INSTALLED_CACHE"
          return 0
        fi
      fi

      echo "Scanning installed packages..." >&2
      write_status "running" "Scanning installed packages"
      local installed_json
      installed_json=$(scan_installed_packages)
      echo "$installed_json" | sponge "$INSTALLED_CACHE"
      echo "Found $(echo "$installed_json" | jq 'length') packages." >&2
      echo "$installed_json"
    }

    # =============================================================================
    # Version comparison
    # =============================================================================

    is_valid_version() {
      local v="$1"
      [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && return 1
      [[ "$v" =~ ^[0-9]{8} ]] && return 1
      [[ "$v" =~ ^[0-9] ]] || return 1
      return 0
    }

    version_less_than() {
      local v1="$1"
      local v2="$2"
      [[ "$v1" == "$v2" ]] && return 1
      is_valid_version "$v1" || return 1
      is_valid_version "$v2" || return 1
      local smaller
      smaller=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)
      [[ "$smaller" == "$v1" ]]
    }

    # =============================================================================
    # Results caching
    # =============================================================================

    save_results() {
      local checked="$1"
      local total="$2"
      local total_updates="$3"
      local -n updates_ref=$4

      local updates_json="[]"
      if [[ ''${#updates_ref[@]} -gt 0 ]]; then
        updates_json=$(printf '%s\n' "''${updates_ref[@]}" | jq -s '.')
      fi

      jq -n \
        --argjson count "$total_updates" \
        --argjson checked "$checked" \
        --argjson total "$total" \
        --argjson updates "$updates_json" \
        --arg timestamp "$(date -Iseconds)" \
        '{count: $count, checked: $checked, total: $total, timestamp: $timestamp, updates: $updates}' | \
        sponge "$UPDATES_CACHE"
    }

    # =============================================================================
    # Main update check
    # =============================================================================

    check_updates() {
      local force_rescan="''${1:-false}"
      local force_recheck="''${2:-false}"
      local force_fetch="''${3:-false}"

      # Try to acquire lock - exit if another instance is running
      if ! acquire_lock; then
        print_warn "Another nixup instance is already running"
        return 1
      fi

      fetch_nixpkgs_index "$force_fetch"
      local installed_json
      installed_json=$(get_installed_packages "$force_rescan")
      local total_packages
      total_packages=$(echo "$installed_json" | jq 'length')

      if [[ "$force_recheck" != "true" && -f "$UPDATES_CACHE" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$UPDATES_CACHE")))
        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
          local cached_total
          cached_total=$(jq -r '.total // 0' "$UPDATES_CACHE")
          if [[ "$cached_total" -eq "$total_packages" && "$cached_total" -gt 0 ]]; then
            cat "$UPDATES_CACHE"
            return 0
          fi
        fi
      fi

      echo "Comparing $total_packages packages..." >&2
      write_status "running" "Checking versions" 0 "$total_packages"

      local updates=()
      local checked=0
      local total_updates=0
      declare -A checked_packages

      while IFS= read -r pkg_json; do
        local name version
        name=$(echo "$pkg_json" | jq -r '.name')
        version=$(echo "$pkg_json" | jq -r '.version')

        [[ -n "''${checked_packages[$name]:-}" ]] && continue
        checked_packages[$name]=1

        ((checked++)) || true
        if (( checked % 50 == 0 )); then
          draw_progress "$checked" "$total_packages" "$total_updates"
          write_status "running" "Checking versions" "$checked" "$total_packages"
        fi

        local latest
        latest=$(get_latest_version "$name")
        [[ -z "$latest" ]] && continue

        if version_less_than "$version" "$latest"; then
          ((total_updates++)) || true
          updates+=("{\"name\":\"$name\",\"installed\":\"$version\",\"latest\":\"$latest\"}")
        fi
      done < <(echo "$installed_json" | jq -c '.[]')

      clear_progress
      echo "Found $total_updates updates." >&2

      save_results "$checked" "$total_packages" "$total_updates" updates
      clear_status
      cat "$UPDATES_CACHE"
    }

    # =============================================================================
    # Config management
    # =============================================================================

    find_hooks() {
      grep -rn "# @nixup:" "$CONFIG_DIR" --include="*.nix" 2>/dev/null | \
        grep -v 'nixup.nix' | grep -v '@nixup:end' | grep -v '<hook-name>' | \
        sed 's/.*@nixup:\([^[:space:]]*\).*/\1/' | sort -u
    }

    find_hook_file() {
      local hook="$1"
      grep -rl "# @nixup:$hook\$" "$CONFIG_DIR" --include="*.nix" 2>/dev/null | \
        grep -v 'nixup.nix' | head -1
    }

    get_hook_items() {
      local hook="$1"
      local file
      file=$(find_hook_file "$hook")
      [[ -z "$file" ]] && return 1
      awk "/# @nixup:$hook\$/{found=1; next} /# @nixup:end/{found=0} found{print}" "$file" | \
        sed 's/^[[:space:]]*//' | { grep -v '^$' || true; } | { grep -v '^#' || true; }
    }

    config_add() {
      local hook="$1"
      local item="$2"
      local file
      file=$(find_hook_file "$hook")

      if [[ -z "$file" ]]; then
        print_error "Hook '$hook' not found"
        echo "Available hooks:"
        find_hooks | sed 's/^/  /'
        return 1
      fi

      get_hook_items "$hook" | grep -qx "$item" && { print_warn "'$item' already exists"; return 0; }

      local line_num
      line_num=$(grep -n "# @nixup:$hook\$" "$file" | cut -d: -f1)
      local indent
      indent=$(sed -n "''${line_num}p" "$file" | sed 's/\(^[[:space:]]*\).*/\1/')

      sed -i "''${line_num}a\\''${indent}$item" "$file"
      print_success "Added '$item' to '$hook'"
      alejandra -q "$file" 2>/dev/null || true
    }

    config_remove() {
      local hook="$1"
      local item="$2"
      local file
      file=$(find_hook_file "$hook")

      [[ -z "$file" ]] && { print_error "Hook '$hook' not found"; return 1; }

      if ! get_hook_items "$hook" | grep -qx "$item"; then
        print_error "'$item' not found in '$hook'"
        return 1
      fi

      local start_line end_line
      start_line=$(grep -n "# @nixup:$hook\$" "$file" | cut -d: -f1)
      end_line=$(awk "NR>$start_line && /# @nixup:end/{print NR; exit}" "$file")

      sed -i "''${start_line},''${end_line}{/^[[:space:]]*''${item}[[:space:]]*\$/d}" "$file"
      print_success "Removed '$item' from '$hook'"
      alejandra -q "$file" 2>/dev/null || true
    }

    config_list() {
      local hook="''${1:-}"

      if [[ -n "$hook" ]]; then
        local file
        file=$(find_hook_file "$hook")
        [[ -z "$file" ]] && { print_error "Hook '$hook' not found"; return 1; }

        echo -e "''${BOLD}Items in '$hook':''${NC}"
        echo -e "''${CYAN}File:''${NC} ''${file#"$CONFIG_DIR/"}"
        echo ""
        get_hook_items "$hook" | while read -r item; do echo "  $item"; done
      else
        echo -e "''${BOLD}Available hooks:''${NC}"
        local hooks
        hooks=$(find_hooks)

        if [[ -z "$hooks" ]]; then
          print_warn "No hooks found"
          echo "To create a hook: # @nixup:my-hook ... # @nixup:end"
          return 0
        fi

        for h in $hooks; do
          local file count
          file=$(find_hook_file "$h")
          count=$(get_hook_items "$h" | wc -l)
          printf "  ''${CYAN}%-20s''${NC} %3d items  ''${BLUE}%s''${NC}\n" "$h" "$count" "''${file#"$CONFIG_DIR/"}"
        done
      fi
    }

    config_search() {
      print_info "Searching nixpkgs for '$1'..."
      nix search nixpkgs "#$1" --no-update-lock-file 2>/dev/null | head -30
    }

    config_init() {
      local file="$1"
      local hook="$2"
      [[ ! "$file" = /* ]] && file="$CONFIG_DIR/$file"
      [[ ! -f "$file" ]] && { print_error "File not found: $file"; return 1; }
      grep -q "# @nixup:$hook\$" "$file" && { print_warn "Hook already exists"; return 0; }

      echo ""
      echo -e "''${BOLD}Hook template:''${NC}"
      echo "  # @nixup:$hook"
      echo "  # @nixup:end"
      echo ""
      echo "Add this to your .nix file inside [ ] or { }"
    }

    config_format() {
      print_info "Formatting .nix files in $CONFIG_DIR..."
      find "$CONFIG_DIR" -name "*.nix" -exec alejandra -q {} \; 2>/dev/null
      print_success "Formatting complete"
    }

    # =============================================================================
    # Diff management
    # =============================================================================

    diff_list() {
      [[ ! -d "$BACKUP_DIR" ]] && { echo "No backups found"; return 0; }

      echo -e "''${BOLD}Backed up dotfiles:''${NC}"
      find "$BACKUP_DIR" -type f -name "*.backup.*" 2>/dev/null | \
        sed 's|.backup.[0-9]*$||' | sort -u | while read -r base; do
          local latest
          latest=$(find "$BACKUP_DIR" -name "$(basename "$base").backup.*" -path "*$base.backup.*" 2>/dev/null | sort -r | head -1)
          [[ -z "$latest" ]] && continue

          local rel="''${latest#"$BACKUP_DIR"/}"
          local orig="''${rel%.backup.*}"
          local ts="''${rel##*.backup.}"

          if [[ "$ts" =~ ^[0-9]{14}$ ]]; then
            ts="''${ts:0:4}-''${ts:4:2}-''${ts:6:2} ''${ts:8:2}:''${ts:10:2}:''${ts:12:2}"
          fi

          echo "  ''${CYAN}$orig''${NC} ($ts)"
        done
    }

    diff_restore() {
      local file="''${1:-}"
      local merge="''${2:-}"

      [[ -z "$file" ]] && { print_error "Usage: nixup diff restore <dotfile>"; return 1; }

      local latest
      latest=$(find "$BACKUP_DIR" -name "$(basename "$file").backup.*" 2>/dev/null | sort -r | head -1)
      [[ -z "$latest" ]] && { print_error "No backup found for $file"; return 1; }

      local XDG_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"
      local XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
      local target=""

      [[ -f "$XDG_CONFIG_HOME/$file" ]] && target="$XDG_CONFIG_HOME/$file"
      [[ -z "$target" && -f "$XDG_DATA_HOME/$file" ]] && target="$XDG_DATA_HOME/$file"
      [[ -z "$target" ]] && { print_error "Cannot find $file"; return 1; }

      if [[ "$merge" == "--merge" ]]; then
        print_info "Showing diff (- = backup, + = current):"
        diff -u "$latest" "$target" || true
        echo ""
        print_warn "Backup: $latest"
        print_warn "Current: $target"
      else
        cp "$latest" "$target"
        print_success "Restored $file"
        print_warn "Will be overwritten on next nixos-rebuild"
      fi
    }

    diff_clear() {
      [[ ! -d "$BACKUP_DIR" ]] && { print_info "No backups"; return 0; }
      local count
      count=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
      [[ "$count" -eq 0 ]] && { print_info "No backups"; return 0; }

      echo -e "''${YELLOW}Warning:''${NC} Delete $count backup(s)?"
      read -r -p "Confirm [y/N]: " response
      [[ "$response" =~ ^[Yy]$ ]] && { rm -rf "$BACKUP_DIR"; print_success "Cleared backups"; } || echo "Cancelled"
    }

    # =============================================================================
    # Dotfiles setup guide
    # =============================================================================

    dotfiles_setup() {
      cat <<'SETUPEOF'
${dotfilesSetupDoc}
SETUPEOF
    }

    # =============================================================================
    # CLI Router
    # =============================================================================

    [[ $# -eq 0 ]] && { usage; exit 0; }

    SUBCOMMAND="$1"
    shift

    case "$SUBCOMMAND" in
      updates)
        [[ $# -eq 0 ]] && { echo "Usage: nixup updates <count|fetch|list>"; exit 1; }
        CMD="$1"
        shift

        FORCE_RESCAN=false
        FORCE_RECHECK=false
        FORCE_FETCH=false

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --rescan) FORCE_RESCAN=true; shift ;;
            --recheck) FORCE_RECHECK=true; shift ;;
            --refresh) FORCE_RESCAN=true; FORCE_RECHECK=true; shift ;;
            --fetch) FORCE_FETCH=true; shift ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
          esac
        done

        case "$CMD" in
          count)
            if check_lock; then
              echo "?"
            else
              [[ -f "$UPDATES_CACHE" ]] && jq -r '.count' "$UPDATES_CACHE" || echo "?"
            fi
            ;;
          tooltip)
            get_tooltip
            ;;
          status)
            get_status
            ;;
          fetch)
            check_updates "$FORCE_RESCAN" "$FORCE_RECHECK" "$FORCE_FETCH" >/dev/null
            ;;
          list)
            result=$(check_updates "$FORCE_RESCAN" "$FORCE_RECHECK" "$FORCE_FETCH")
            count=$(echo "$result" | jq -r '.count')
            if [[ "$count" -eq 0 ]]; then
              echo "All packages are up to date!"
            else
              echo "Updates available ($count):"
              echo "$result" | jq -r '.updates[] | "  \(.name): \(.installed) → \(.latest)"'
            fi
            ;;
          open)
            # Open terminal with update list (for left-click action)
            terminal="''${TERMINAL:-''${TERM:-xterm}}"
            exec "$terminal" -e nixup updates list
            ;;
          *) print_error "Unknown command: $CMD"; exit 1 ;;
        esac
        ;;

      config)
        [[ $# -eq 0 ]] && { echo "Usage: nixup config <list|add|rm|search|init|format>"; exit 1; }
        CMD="$1"
        shift

        case "$CMD" in
          list) config_list "''${1:-}" ;;
          add)
            [[ $# -lt 2 ]] && { print_error "Usage: nixup config add <hook> <item>"; exit 1; }
            config_add "$1" "$2"
            ;;
          rm|remove)
            [[ $# -lt 2 ]] && { print_error "Usage: nixup config rm <hook> <item>"; exit 1; }
            config_remove "$1" "$2"
            ;;
          search)
            [[ $# -lt 1 ]] && { print_error "Usage: nixup config search <query>"; exit 1; }
            config_search "$1"
            ;;
          init)
            [[ $# -lt 2 ]] && { print_error "Usage: nixup config init <file> <hook>"; exit 1; }
            config_init "$1" "$2"
            ;;
          format) config_format ;;
          *) print_error "Unknown command: $CMD"; exit 1 ;;
        esac
        ;;

      diff)
        [[ $# -eq 0 ]] && { echo "Usage: nixup diff <list|restore|clear>"; exit 1; }
        CMD="$1"
        shift

        case "$CMD" in
          list) diff_list ;;
          restore) diff_restore "$@" ;;
          clear) diff_clear ;;
          *) print_error "Unknown command: $CMD"; exit 1 ;;
        esac
        ;;

      dotfiles)
        [[ $# -eq 0 ]] && { echo "Usage: nixup dotfiles <setup>"; exit 1; }
        CMD="$1"
        shift

        case "$CMD" in
          setup) dotfiles_setup ;;
          *) print_error "Unknown command: $CMD"; exit 1 ;;
        esac
        ;;

      -h|--help|help) usage ;;

      *) print_error "Unknown command: $SUBCOMMAND"; usage; exit 1 ;;
    esac
  '';
}
