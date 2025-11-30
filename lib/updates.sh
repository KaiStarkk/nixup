#!/usr/bin/env bash
# updates.sh - Version comparison, results caching, and main update checking

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
  if [[ ${#updates_ref[@]} -gt 0 ]]; then
    updates_json=$(printf '%s\n' "${updates_ref[@]}" | jq -s '.')
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
# Versioned variant detection
# =============================================================================

# Check if an update is a false positive due to versioned variants
is_versioned_variant() {
  local name="$1"
  local installed_version="$2"
  local latest_version="$3"

  # Extract major version from installed version
  local major_version=""
  if [[ "$installed_version" =~ ^([0-9]+)\. ]]; then
    major_version="${BASH_REMATCH[1]}"
  elif [[ "$installed_version" =~ ^([0-9]+)$ ]]; then
    major_version="$installed_version"
  fi

  [[ -z "$major_version" ]] && return 1

  # Check if latest version has a different major version
  local latest_major=""
  if [[ "$latest_version" =~ ^([0-9]+)\. ]]; then
    latest_major="${BASH_REMATCH[1]}"
  elif [[ "$latest_version" =~ ^([0-9]+)$ ]]; then
    latest_major="$latest_version"
  fi

  # If major versions are the same, this is not a versioned variant issue
  [[ "$major_version" == "$latest_major" ]] && return 1

  # Check if a versioned variant exists in nixpkgs (e.g., tesseract4)
  local versioned_name="${name}${major_version}"
  local versioned_version
  versioned_version=$(get_latest_version "$versioned_name")

  # If versioned variant exists and matches installed version, it's a false positive
  if [[ -n "$versioned_version" && "$versioned_version" == "$installed_version" ]]; then
    return 0
  fi

  # Check for version-prefixed variants (e.g., qt5.qtbase for qt5 packages)
  # Common patterns: qt5, qt4, python39, lua54, etc.
  for prefix in "qt$major_version" "python$major_version" "lua$major_version" "php$major_version"; do
    versioned_name="${prefix}.${name}"
    versioned_version=$(get_latest_version "$versioned_name")
    if [[ -n "$versioned_version" && "$versioned_version" == "$installed_version" ]]; then
      return 0
    fi
  done

  return 1
}

# =============================================================================
# Main update check
# =============================================================================

check_updates() {
  local force_rescan="${1:-false}"
  local force_recheck="${2:-false}"
  local force_fetch="${3:-false}"

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
  write_status "check_versions" 0 "$total_packages"

  local updates=()
  local checked=0
  local total_updates=0
  declare -A checked_packages

  while IFS= read -r pkg_json; do
    local name version
    name=$(echo "$pkg_json" | jq -r '.name')
    version=$(echo "$pkg_json" | jq -r '.version')

    [[ -n "${checked_packages[$name]:-}" ]] && continue
    checked_packages[$name]=1

    ((checked++)) || true
    if (( checked % 50 == 0 )); then
      draw_progress "$checked" "$total_packages" "$total_updates"
      write_status "check_versions" "$checked" "$total_packages"
    fi

    local latest
    latest=$(get_latest_version "$name")
    [[ -z "$latest" ]] && continue

    if version_less_than "$version" "$latest"; then
      # Skip if this is a versioned variant (e.g., tesseract4 vs tesseract5)
      if is_versioned_variant "$name" "$version" "$latest"; then
        continue
      fi

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
