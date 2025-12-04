#!/usr/bin/env bash
# packages.sh - Package parsing, filtering, nixpkgs index, and installed package scanning

# =============================================================================
# Config-based package extraction
# =============================================================================

# Extract package names explicitly listed in nix config files
# Looks for patterns like: pkgs.packageName, home.packages = [ packageName ]
get_config_packages() {
  local packages=()

  # Find all .nix files in config directory
  while IFS= read -r file; do
    # Extract package names from various patterns:
    # - pkgs.packageName (direct references)
    # - packageName in lists after home.packages, environment.systemPackages
    # - items between @nixup: hooks

    # Pattern 1: pkgs.something or pkgs.lib.something at word boundaries
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(grep -oE '\bpkgs\.[a-zA-Z0-9_-]+' "$file" 2>/dev/null | sed 's/pkgs\.//' | sort -u)

    # Pattern 2: items in @nixup:packages or @nixup:dev-tools hooks
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(awk '/@nixup:(packages|dev-tools)$/{found=1; next} /@nixup:end/{found=0} found{print}' "$file" 2>/dev/null | \
      sed 's/^[[:space:]]*//' | grep -v '^$' | grep -v '^#' | sort -u)

  done < <(find "$CONFIG_DIR" -name "*.nix" -type f 2>/dev/null)

  # Output unique package names
  printf '%s\n' "${packages[@]}" | sort -u
}

# Extract program names from programs.*.enable = true patterns
get_programs_packages() {
  local programs=()

  while IFS= read -r file; do
    # Pattern: programs.name.enable or programs.name = { enable = true
    while IFS= read -r prog; do
      [[ -n "$prog" ]] && programs+=("$prog")
    done < <(grep -oE 'programs\.[a-zA-Z0-9_-]+\.(enable|settings)' "$file" 2>/dev/null | \
      sed 's/programs\.\([^.]*\)\..*/\1/' | sort -u)

    # Also catch: programName.enable = true; pattern for home-manager
    while IFS= read -r prog; do
      [[ -n "$prog" ]] && programs+=("$prog")
    done < <(grep -oE '^[[:space:]]*[a-zA-Z0-9_-]+\.enable\s*=' "$file" 2>/dev/null | \
      sed 's/^[[:space:]]*\([^.]*\)\.enable.*/\1/' | sort -u)
  done < <(find "$CONFIG_DIR" -name "*.nix" -type f 2>/dev/null)

  printf '%s\n' "${programs[@]}" | sort -u
}

# Get the allowlist of packages based on filter mode
get_package_allowlist() {
  local mode="${1:-$(get_filter_mode)}"
  local allowlist=()

  case "$mode" in
    0) # Packages only
      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && allowlist+=("$pkg")
      done < <(get_config_packages)
      ;;
    1) # Packages + Programs
      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && allowlist+=("$pkg")
      done < <(get_config_packages)
      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && allowlist+=("$pkg")
      done < <(get_programs_packages)
      ;;
    2|3) # All modes - return empty (no filtering by allowlist)
      ;;
  esac

  printf '%s\n' "${allowlist[@]}" | sort -u
}

# Check if a package name matches the allowlist (for modes 0 and 1)
is_in_allowlist() {
  local name="$1"
  local mode="${2:-$(get_filter_mode)}"

  # Modes 2 and 3 don't use allowlist filtering
  [[ "$mode" -ge 2 ]] && return 0

  local allowlist_file="$CACHE_DIR/allowlist-mode-$mode.txt"

  # Cache the allowlist for performance
  if [[ ! -f "$allowlist_file" ]] || [[ $(stat -c %Y "$allowlist_file" 2>/dev/null || echo 0) -lt $(($(date +%s) - 300)) ]]; then
    get_package_allowlist "$mode" > "$allowlist_file"
  fi

  # Check if name matches any allowlist entry (case-insensitive prefix match)
  local name_lower="${name,,}"
  while IFS= read -r allowed; do
    local allowed_lower="${allowed,,}"
    # Exact match or the installed package starts with the config name
    if [[ "$name_lower" == "$allowed_lower" ]] || [[ "$name_lower" == "${allowed_lower}-"* ]]; then
      return 0
    fi
  done < "$allowlist_file"

  return 1
}

# =============================================================================
# Package parsing
# =============================================================================

parse_store_path() {
  local path="$1"
  local basename
  basename=$(basename "$path")
  local name_version="${basename:33}"

  if [[ "$name_version" =~ ^(.+)-([0-9][0-9._a-zA-Z-]*)$ ]]; then
    local name="${BASH_REMATCH[1]}"
    local version="${BASH_REMATCH[2]}"
    version=$(echo "$version" | sed -E "s/[_-]($VERSION_SUFFIXES)\$//")
    local version_len=${#version}
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
  local mode="${2:-$(get_filter_mode)}"

  # Mode 3 (verbose) has no exclusions
  [[ "$mode" -eq 3 ]] && return 1

  eval "case \"\$name\" in $EXCLUDE_PATTERNS) return 0 ;; esac"
  return 1
}

# =============================================================================
# Nixpkgs index
# =============================================================================

fetch_nixpkgs_index() {
  local force="${1:-false}"

  if [[ "$force" != "true" && -f "$NIXPKGS_CACHE" ]]; then
    local cache_age
    cache_age=$(($(date +%s) - $(stat -c %Y "$NIXPKGS_CACHE")))
    if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
      return 0
    fi
  fi

  echo "Fetching nixpkgs package index..." >&2
  write_status "fetch_index"
  nix search "$NIXPKGS_REF" "" --json 2>/dev/null | \
    jq 'to_entries
      | map(
          # Extract package name, preserving version prefixes like qt5, python3Packages
          .key as $fullkey |
          ($fullkey | split(".")) as $parts |
          ($parts | last) as $basename |
          # Check if parent is a version prefix (qt5, python39, etc)
          (if ($parts | length) > 3 then
            ($parts[-2] // "") as $parent |
            if ($parent | test("^(qt[0-9]|python[0-9]+|lua[0-9]+|php[0-9]+|ruby_[0-9_]+)")) then
              $parent + "." + $basename
            else
              $basename
            end
          else
            $basename
          end) as $key |
          {
            key: $key,
            value: .value.version,
            depth: ($parts | length)
          }
        )
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
    local name="${parsed%%|*}"
    local version="${parsed##*|}"

    [[ -z "$version" ]] && continue
    is_excluded "$name" && continue
    [[ ${#name} -lt $MIN_NAME_LENGTH ]] && continue

    installed+=("{\"name\":\"$name\",\"version\":\"$version\"}")
  done < <(nix path-info -r "$SYSTEM_PATH" 2>/dev/null | sort -u)

  printf '%s\n' "${installed[@]}" | \
    jq -s 'group_by(.name) | map(.[0]) | sort_by(.name)'
}

get_installed_packages() {
  local force_rescan="${1:-false}"

  if [[ "$force_rescan" != "true" && -f "$INSTALLED_CACHE" ]]; then
    local cache_age
    cache_age=$(($(date +%s) - $(stat -c %Y "$INSTALLED_CACHE")))
    if [[ $cache_age -lt $CACHE_MAX_AGE ]]; then
      cat "$INSTALLED_CACHE"
      return 0
    fi
  fi

  echo "Scanning installed packages..." >&2
  write_status "scan_installed"
  local installed_json
  installed_json=$(scan_installed_packages)
  echo "$installed_json" | sponge "$INSTALLED_CACHE"
  echo "Found $(echo "$installed_json" | jq 'length') packages." >&2
  echo "$installed_json"
}
