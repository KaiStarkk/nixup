#!/usr/bin/env bash
# packages.sh - Package parsing, filtering, nixpkgs index, and installed package scanning

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
