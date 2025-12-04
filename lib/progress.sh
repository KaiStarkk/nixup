#!/usr/bin/env bash
# progress.sh - Progress bar rendering and status tracking for status bars

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
  local width="${3:-10}"

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

# Write current operation status to file
write_status() {
  local phase="$1"
  local progress="${2:-0}"
  local total="${3:-0}"

  local progress_bar=""
  if [[ "$total" -gt 0 ]]; then
    progress_bar=$(make_progress_bar "$progress" "$total" 20)
  fi

  jq -n \
    --arg phase "$phase" \
    --argjson progress "$progress" \
    --argjson total "$total" \
    --arg bar "$progress_bar" \
    '{phase: $phase, progress: $progress, total: $total, bar: $bar}' > "$STATUS_FILE"
}

clear_status() {
  rm -f "$STATUS_FILE"
}

# Unified tooltip: shows progress when busy, updates when idle
get_tooltip() {
  local max_items=5
  local mode
  mode=$(get_filter_mode)
  local mode_name
  mode_name=$(get_filter_mode_name "$mode")

  # Check if refresh is running
  if check_lock; then
    if [[ -f "$STATUS_FILE" ]]; then
      local phase progress total bar
      phase=$(jq -r '.phase // "working"' "$STATUS_FILE" 2>/dev/null)
      progress=$(jq -r '.progress // 0' "$STATUS_FILE" 2>/dev/null)
      total=$(jq -r '.total // 0' "$STATUS_FILE" 2>/dev/null)
      bar=$(jq -r '.bar // ""' "$STATUS_FILE" 2>/dev/null)

      case "$phase" in
        fetch_index)
          echo "Fetching package index..."
          ;;
        scan_installed)
          echo "Scanning installed packages..."
          ;;
        check_versions)
          if [[ "$total" -gt 0 ]]; then
            echo "$bar"
            echo "Checking $progress/$total"
          else
            echo "Comparing versions..."
          fi
          ;;
        *)
          echo "Working..."
          ;;
      esac
    else
      echo "Starting..."
    fi
    return
  fi

  # Not busy - show results
  if [[ ! -f "$UPDATES_CACHE" ]]; then
    echo "[$mode_name]"
    echo "No data"
    return
  fi

  # Get filtered updates based on current mode
  local filtered_json
  filtered_json=$(filter_updates_by_mode "$mode")
  local count
  count=$(echo "$filtered_json" | jq -r '.count')

  # Show mode header
  echo "[$mode_name]"

  if [[ "$count" -eq 0 ]]; then
    echo "Up to date"
    echo ""
    echo "Scroll to change mode"
    return
  fi

  echo "$count updates"
  echo ""

  local shown=0
  while IFS= read -r line; do
    echo "$line"
    ((shown++)) || true
  done < <(echo "$filtered_json" | jq -r '.updates[:'"$max_items"'] | .[] | "\(.name) \(.installed) → \(.latest)"')

  local remaining=$((count - shown))
  if [[ $remaining -gt 0 ]]; then
    echo ""
    echo "+$remaining more"
  fi

  echo ""
  echo "Scroll to change mode"
}
