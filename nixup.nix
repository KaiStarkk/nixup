{
  writeShellApplication,
  jq,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  moreutils,
  ncurses,
}:
writeShellApplication {
  name = "nixup";
  runtimeInputs = [
    jq
    coreutils
    gnugrep
    gawk
    gnused
    moreutils # provides sponge for atomic writes
    ncurses # provides tput for terminal control
  ];
  text = ''
    set -euo pipefail

    # =============================================================================
    # Configuration (all overridable via environment variables)
    # =============================================================================

    # Cache location and validity
    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/nixup"
    CACHE_MAX_AGE=''${NIX_UPDATE_CACHE_AGE:-21600}  # 6 hours default

    # Nixpkgs reference to compare against
    NIXPKGS_REF=''${NIX_UPDATE_NIXPKGS_REF:-"github:nixos/nixpkgs/nixos-unstable"}

    # System path to scan for installed packages
    SYSTEM_PATH=''${NIX_UPDATE_SYSTEM_PATH:-"/run/current-system"}

    # Minimum package name length (filters noise)
    MIN_NAME_LENGTH=''${NIX_UPDATE_MIN_NAME_LENGTH:-3}

    # Exclude patterns (pipe-separated glob patterns for case statement)
    # These are low-level build dependencies that clutter the update list
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

    # Version suffixes to strip (nix output names, not version parts)
    DEFAULT_VERSION_SUFFIXES="lib|bin|dev|out|doc|man|info|debug|terminfo|py|nc|pam|data|npm-deps|only-plugins-qml|fish-completions"
    VERSION_SUFFIXES=''${NIX_UPDATE_VERSION_SUFFIXES:-"$DEFAULT_VERSION_SUFFIXES"}

    # =============================================================================
    # Derived paths
    # =============================================================================

    UPDATES_CACHE="$CACHE_DIR/updates.json"
    INSTALLED_CACHE="$CACHE_DIR/installed.json"
    NIXPKGS_CACHE="$CACHE_DIR/nixpkgs-versions.json"

    mkdir -p "$CACHE_DIR"

    # Terminal width for progress bar
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    BAR_WIDTH=$((TERM_WIDTH - 45))
    [[ $BAR_WIDTH -lt 20 ]] && BAR_WIDTH=20

    # =============================================================================
    # Help
    # =============================================================================

    usage() {
      cat <<EOF
    Usage: nixup [COMMAND] [OPTIONS]

    Commands:
      check       Check for updates (default, uses cache)
      count       Output just the update count (for status bars)
      json        Output full JSON (for scripts)
      list        Human-readable list of updates
      installed   Show detected installed packages

    Options:
      --rescan      Force rescan of installed packages
      --recheck     Force recheck of package versions
      --refresh     Force both rescan and recheck
      --fetch       Force re-fetch of nixpkgs package index
      -h, --help    Show this help

    How it works:
      1. Evaluates nixpkgs ONCE to build a local index (~17MB, ~5 seconds)
      2. Scans your installed packages from $SYSTEM_PATH
      3. Compares versions with instant local lookups

    Environment Variables:
      NIX_UPDATE_CACHE_AGE        Cache validity in seconds (default: 21600 = 6h)
      NIX_UPDATE_NIXPKGS_REF      Nixpkgs flake ref (default: github:nixos/nixpkgs/nixos-unstable)
      NIX_UPDATE_SYSTEM_PATH      Path to scan (default: /run/current-system)
      NIX_UPDATE_MIN_NAME_LENGTH  Min package name length (default: 3)
      NIX_UPDATE_EXCLUDE          Exclude patterns, pipe-separated globs
      NIX_UPDATE_VERSION_SUFFIXES Version suffixes to strip, pipe-separated

    Cache files stored in: $CACHE_DIR
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
    # Package parsing
    # =============================================================================

    # Extract package name and version from a nix store path
    parse_store_path() {
      local path="$1"
      local basename
      basename=$(basename "$path")
      local name_version="''${basename:33}"

      # Try to extract name and version
      # Most packages follow: name-version pattern where version starts with a digit
      if [[ "$name_version" =~ ^(.+)-([0-9][0-9._a-zA-Z-]*)$ ]]; then
        local name="''${BASH_REMATCH[1]}"
        local version="''${BASH_REMATCH[2]}"

        # Strip output/build suffixes from version
        # These are nix output names or build variants, not part of the actual version
        version=$(echo "$version" | sed -E "s/[_-]($VERSION_SUFFIXES)\$//")

        # If version is now just a single digit, the package name might include a version
        # e.g., "dbus-1.14.10" parsed as name="dbus-1" version="14.10" is wrong
        # In this case, return empty to skip this package
        local version_len=''${#version}
        if [[ "$version" =~ ^[0-9]+$ && $version_len -le 2 ]]; then
          # Check if name ends with a digit - might be versioned name like qt5, python3
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

    # Check if package should be excluded
    is_excluded() {
      local name="$1"
      # Use eval to expand the glob patterns in the case statement
      eval "case \"\$name\" in $EXCLUDE_PATTERNS) return 0 ;; esac"
      return 1
    }

    # =============================================================================
    # Nixpkgs index
    # =============================================================================

    # Fetch all nixpkgs packages and versions in one evaluation
    fetch_nixpkgs_index() {
      local force="''${1:-false}"

      if [[ "$force" != "true" && -f "$NIXPKGS_CACHE" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$NIXPKGS_CACHE")))
        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
          return 0
        fi
      fi

      echo "Fetching nixpkgs package index from $NIXPKGS_REF..." >&2
      echo "  (this takes ~5 seconds on first run)" >&2

      # Evaluate all packages, extract name -> version mapping
      # Output format: { "firefox": "128.0", "git": "2.45.0", ... }
      # Prefer top-level packages (shorter paths) over nested ones like xxxPackages.foo
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

    # Get latest version from cached nixpkgs index (instant)
    get_latest_version() {
      local pkg_name="$1"
      jq -r --arg name "$pkg_name" '.[$name] // empty' "$NIXPKGS_CACHE"
    }

    # =============================================================================
    # Installed package scanning
    # =============================================================================

    # Get all user-visible packages from the current system closure
    scan_installed_packages() {
      local installed=()

      while IFS= read -r path; do
        local parsed
        parsed=$(parse_store_path "$path")
        local name="''${parsed%%|*}"
        local version="''${parsed##*|}"

        [[ -z "$version" ]] && continue

        # Check exclusion patterns
        if is_excluded "$name"; then
          continue
        fi

        [[ ''${#name} -lt $MIN_NAME_LENGTH ]] && continue

        installed+=("{\"name\":\"$name\",\"version\":\"$version\"}")
      done < <(nix path-info -r "$SYSTEM_PATH" 2>/dev/null | sort -u)

      printf '%s\n' "''${installed[@]}" | \
        jq -s 'group_by(.name) | map(.[0]) | sort_by(.name)'
    }

    # Get installed packages (from cache or fresh scan)
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

      echo "Scanning installed packages from $SYSTEM_PATH..." >&2
      local installed_json
      installed_json=$(scan_installed_packages)
      echo "$installed_json" | sponge "$INSTALLED_CACHE"
      local count
      count=$(echo "$installed_json" | jq 'length')
      echo "Found $count packages." >&2
      echo "$installed_json"
    }

    # =============================================================================
    # Version comparison
    # =============================================================================

    # Check if a version looks valid (not a date or weird format)
    is_valid_version() {
      local v="$1"
      # Skip if it looks like a date (YYYY-MM-DD or YYYYMMDD)
      [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && return 1
      [[ "$v" =~ ^[0-9]{8} ]] && return 1
      # Must start with a digit
      [[ "$v" =~ ^[0-9] ]] || return 1
      return 0
    }

    # Compare versions (returns 0 if v1 < v2)
    version_less_than() {
      local v1="$1"
      local v2="$2"
      [[ "$v1" == "$v2" ]] && return 1

      # Skip comparison if either version looks invalid
      is_valid_version "$v1" || return 1
      is_valid_version "$v2" || return 1

      local smaller
      smaller=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)
      [[ "$smaller" == "$v1" ]]
    }

    # =============================================================================
    # Results caching
    # =============================================================================

    # Save results to cache (atomic write via sponge)
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
        --arg nixpkgs_ref "$NIXPKGS_REF" \
        '{
          count: $count,
          checked: $checked,
          total: $total,
          timestamp: $timestamp,
          nixpkgs_ref: $nixpkgs_ref,
          updates: $updates
        }' | sponge "$UPDATES_CACHE"
    }

    # =============================================================================
    # Main update check
    # =============================================================================

    check_updates() {
      local force_rescan="''${1:-false}"
      local force_recheck="''${2:-false}"
      local force_fetch="''${3:-false}"

      # Ensure nixpkgs index exists
      fetch_nixpkgs_index "$force_fetch"

      # Get installed packages
      local installed_json
      installed_json=$(get_installed_packages "$force_rescan")

      local total_packages
      total_packages=$(echo "$installed_json" | jq 'length')

      # Check for valid cached results
      if [[ "$force_recheck" != "true" && -f "$UPDATES_CACHE" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$UPDATES_CACHE")))

        if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
          local cached_checked cached_total
          cached_checked=$(jq -r '.checked // 0' "$UPDATES_CACHE")
          cached_total=$(jq -r '.total // 0' "$UPDATES_CACHE")

          [[ -z "$cached_checked" || "$cached_checked" == "null" ]] && cached_checked=0
          [[ -z "$cached_total" || "$cached_total" == "null" ]] && cached_total=0

          # If complete and valid, return cached result
          if [[ "$cached_checked" -ge "$cached_total" && "$cached_total" -eq "$total_packages" && "$cached_total" -gt 0 ]]; then
            cat "$UPDATES_CACHE"
            return 0
          fi
        fi
      fi

      echo "Comparing $total_packages packages against $NIXPKGS_REF..." >&2

      local updates=()
      local checked=0
      local total_updates=0
      local found_in_nixpkgs=0

      # Track packages we've already checked to avoid duplicates
      declare -A checked_packages

      while IFS= read -r pkg_json; do
        local name version
        name=$(echo "$pkg_json" | jq -r '.name')
        version=$(echo "$pkg_json" | jq -r '.version')

        # Skip if we've already checked this package
        if [[ -n "''${checked_packages[$name]:-}" ]]; then
          continue
        fi
        checked_packages[$name]=1

        ((checked++)) || true

        # Progress update every 50 packages
        if (( checked % 50 == 0 )); then
          draw_progress "$checked" "$total_packages" "$total_updates"
        fi

        # Instant lookup from cached index
        local latest
        latest=$(get_latest_version "$name")

        [[ -z "$latest" ]] && continue
        ((found_in_nixpkgs++)) || true

        if version_less_than "$version" "$latest"; then
          ((total_updates++)) || true
          updates+=("{\"name\":\"$name\",\"installed\":\"$version\",\"latest\":\"$latest\"}")
        fi
      done < <(echo "$installed_json" | jq -c '.[]')

      clear_progress
      echo "Done! Found $total_updates updates ($found_in_nixpkgs/$checked packages matched in nixpkgs)." >&2

      save_results "$checked" "$total_packages" "$total_updates" updates
      cat "$UPDATES_CACHE"
    }

    # =============================================================================
    # CLI
    # =============================================================================

    COMMAND="check"
    FORCE_RESCAN=false
    FORCE_RECHECK=false
    FORCE_FETCH=false

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --rescan)
          FORCE_RESCAN=true
          shift
          ;;
        --recheck)
          FORCE_RECHECK=true
          shift
          ;;
        --refresh)
          FORCE_RESCAN=true
          FORCE_RECHECK=true
          shift
          ;;
        --fetch)
          FORCE_FETCH=true
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        -*)
          echo "Unknown option: $1" >&2
          usage >&2
          exit 1
          ;;
        *)
          COMMAND="$1"
          shift
          ;;
      esac
    done

    case "$COMMAND" in
      check)
        check_updates "$FORCE_RESCAN" "$FORCE_RECHECK" "$FORCE_FETCH"
        ;;
      count)
        if [[ -f "$UPDATES_CACHE" ]]; then
          jq -r '.count' "$UPDATES_CACHE"
        else
          echo "?"
        fi
        ;;
      json)
        check_updates "$FORCE_RESCAN" "$FORCE_RECHECK" "$FORCE_FETCH"
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
      installed)
        if [[ "$FORCE_RESCAN" == "true" ]]; then
          get_installed_packages true >/dev/null
        fi
        if [[ -f "$INSTALLED_CACHE" ]]; then
          jq -r '.[] | "\(.name) \(.version)"' "$INSTALLED_CACHE" | column -t
        else
          echo "No installed package cache. Run 'nixup --rescan' first."
        fi
        ;;
      *)
        echo "Unknown command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
    esac
  '';
}
