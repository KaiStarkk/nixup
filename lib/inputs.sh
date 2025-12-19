#!/usr/bin/env bash
# inputs.sh - Flake input version tracking

# =============================================================================
# Configuration
# =============================================================================

INPUTS_CACHE="$CACHE_DIR/inputs.json"
INPUTS_CACHE_AGE=${NIXUP_INPUTS_CACHE_AGE:-3600}  # 1 hour default
FLAKE_LOCK="$CONFIG_DIR/flake.lock"

# =============================================================================
# Flake lock parsing
# =============================================================================

# Get list of GitHub inputs from flake.lock
get_github_inputs() {
  if [[ ! -f "$FLAKE_LOCK" ]]; then
    print_error "flake.lock not found at $FLAKE_LOCK"
    return 1
  fi

  # Extract GitHub inputs with their locked info
  jq -r '
    .nodes | to_entries[] |
    select(.value.locked.type == "github") |
    select(.key != "root") |
    {
      name: .key,
      owner: .value.locked.owner,
      repo: .value.locked.repo,
      rev: .value.locked.rev,
      ref: (.value.original.ref // "HEAD"),
      lastModified: .value.locked.lastModified
    }
  ' "$FLAKE_LOCK"
}

# =============================================================================
# GitHub API queries
# =============================================================================

# Get latest commit for a GitHub repo
get_latest_commit() {
  local owner="$1"
  local repo="$2"
  local ref="${3:-HEAD}"

  # Use gh api to get latest commit
  local result
  if [[ "$ref" == "HEAD" ]]; then
    result=$(gh api "repos/$owner/$repo/commits/HEAD" --jq '{sha: .sha, date: .commit.committer.date}' 2>/dev/null)
  else
    result=$(gh api "repos/$owner/$repo/commits/$ref" --jq '{sha: .sha, date: .commit.committer.date}' 2>/dev/null)
  fi

  if [[ -z "$result" || "$result" == "null" ]]; then
    echo ""
    return 1
  fi

  echo "$result"
}

# =============================================================================
# Input checking
# =============================================================================

check_inputs() {
  local force="${1:-false}"

  # Check cache validity
  if [[ "$force" != "true" && -f "$INPUTS_CACHE" ]]; then
    local cache_age
    cache_age=$(($(date +%s) - $(stat -c %Y "$INPUTS_CACHE")))
    if [[ $cache_age -lt $INPUTS_CACHE_AGE ]]; then
      cat "$INPUTS_CACHE"
      return 0
    fi
  fi

  echo "Checking flake inputs..." >&2

  local inputs_json
  inputs_json=$(get_github_inputs)

  if [[ -z "$inputs_json" ]]; then
    jq -n '{count: 0, inputs: [], timestamp: now | todate}' > "$INPUTS_CACHE"
    cat "$INPUTS_CACHE"
    return 0
  fi

  local results=()
  local outdated_count=0
  local total=0

  while IFS= read -r input; do
    [[ -z "$input" ]] && continue
    ((total++)) || true

    local name owner repo rev ref lastModified
    name=$(echo "$input" | jq -r '.name')
    owner=$(echo "$input" | jq -r '.owner')
    repo=$(echo "$input" | jq -r '.repo')
    rev=$(echo "$input" | jq -r '.rev')
    ref=$(echo "$input" | jq -r '.ref')
    lastModified=$(echo "$input" | jq -r '.lastModified')

    echo "  Checking $name..." >&2

    local latest
    latest=$(get_latest_commit "$owner" "$repo" "$ref")

    if [[ -z "$latest" ]]; then
      # Couldn't fetch, mark as unknown
      results+=("{\"name\":\"$name\",\"owner\":\"$owner\",\"repo\":\"$repo\",\"locked\":\"$rev\",\"latest\":\"unknown\",\"outdated\":false,\"lockedDate\":$lastModified}")
      continue
    fi

    local latest_sha latest_date
    latest_sha=$(echo "$latest" | jq -r '.sha')
    latest_date=$(echo "$latest" | jq -r '.date')

    local outdated=false
    if [[ "$rev" != "$latest_sha" ]]; then
      outdated=true
      ((outdated_count++)) || true
    fi

    # Calculate days behind
    local locked_epoch latest_epoch days_behind
    locked_epoch=$lastModified
    latest_epoch=$(date -d "$latest_date" +%s 2>/dev/null || echo "$locked_epoch")
    days_behind=$(( (latest_epoch - locked_epoch) / 86400 ))
    [[ $days_behind -lt 0 ]] && days_behind=0

    results+=("{\"name\":\"$name\",\"owner\":\"$owner\",\"repo\":\"$repo\",\"locked\":\"${rev:0:7}\",\"latest\":\"${latest_sha:0:7}\",\"outdated\":$outdated,\"lockedDate\":$lastModified,\"daysBehind\":$days_behind}")
  done < <(echo "$inputs_json" | jq -c '.')

  # Build final JSON
  local all_inputs="[]"
  if [[ ${#results[@]} -gt 0 ]]; then
    all_inputs=$(printf '%s\n' "${results[@]}" | jq -s '.')
  fi

  jq -n \
    --argjson count "$outdated_count" \
    --argjson total "$total" \
    --argjson inputs "$all_inputs" \
    --arg timestamp "$(date -Iseconds)" \
    '{count: $count, total: $total, timestamp: $timestamp, inputs: $inputs}' > "$INPUTS_CACHE"

  cat "$INPUTS_CACHE"
}

# =============================================================================
# Output functions
# =============================================================================

inputs_count() {
  if [[ ! -f "$INPUTS_CACHE" ]]; then
    echo "?"
    return
  fi

  jq -r '.count' "$INPUTS_CACHE"
}

inputs_tooltip() {
  local max_items=8

  if [[ ! -f "$INPUTS_CACHE" ]]; then
    echo "[Flake Inputs]"
    echo "No data - run 'nixup inputs fetch'"
    return
  fi

  local data
  data=$(cat "$INPUTS_CACHE")
  local count total
  count=$(echo "$data" | jq -r '.count')
  total=$(echo "$data" | jq -r '.total')

  echo "[Flake Inputs]"

  if [[ "$count" -eq 0 ]]; then
    echo "All $total inputs up to date"
    return
  fi

  echo "$count/$total outdated"
  echo ""

  local shown=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name locked latest days
    name=$(echo "$line" | jq -r '.name')
    locked=$(echo "$line" | jq -r '.locked')
    latest=$(echo "$line" | jq -r '.latest')
    days=$(echo "$line" | jq -r '.daysBehind // 0')

    if [[ "$days" -gt 0 ]]; then
      echo "$name: $locked → $latest (${days}d behind)"
    else
      echo "$name: $locked → $latest"
    fi
    ((shown++)) || true
  done < <(echo "$data" | jq -c '.inputs[] | select(.outdated == true)' | head -n "$max_items")

  local remaining=$((count - shown))
  if [[ $remaining -gt 0 ]]; then
    echo ""
    echo "+$remaining more"
  fi
}

inputs_list() {
  local force="${1:-false}"

  # Ensure we have data
  check_inputs "$force" >/dev/null

  if [[ ! -f "$INPUTS_CACHE" ]]; then
    print_error "No input data available"
    return 1
  fi

  local data
  data=$(cat "$INPUTS_CACHE")
  local count total
  count=$(echo "$data" | jq -r '.count')
  total=$(echo "$data" | jq -r '.total')

  echo "Flake Inputs ($count/$total outdated)"
  echo ""

  if [[ "$count" -eq 0 ]]; then
    echo "All inputs are up to date!"
    echo ""
    echo "$data" | jq -r '.inputs[] | "  ✓ \(.name) (\(.locked))"'
  else
    echo "Outdated:"
    echo "$data" | jq -r '.inputs[] | select(.outdated == true) | "  ✗ \(.name): \(.locked) → \(.latest) (\(.daysBehind // 0)d behind)"'
    echo ""
    echo "Up to date:"
    echo "$data" | jq -r '.inputs[] | select(.outdated == false) | "  ✓ \(.name) (\(.locked))"'
  fi

  echo ""
  echo "Update with: nix flake update <input-name>"
  echo "Update all:  nix flake update"
}
