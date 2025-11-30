#!/usr/bin/env bash
# config.sh - Configuration hook management (find, list, add, remove, init)

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
  indent=$(sed -n "${line_num}p" "$file" | sed 's/\(^[[:space:]]*\).*/\1/')

  sed -i "${line_num}a\\${indent}$item" "$file"
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

  sed -i "${start_line},${end_line}{/^[[:space:]]*${item}[[:space:]]*\$/d}" "$file"
  print_success "Removed '$item' from '$hook'"
  alejandra -q "$file" 2>/dev/null || true
}

config_set() {
  local hook="$1"
  local value="$2"
  local file
  file=$(find_hook_file "$hook")

  if [[ -z "$file" ]]; then
    print_error "Hook '$hook' not found"
    echo "Available hooks:"
    find_hooks | sed 's/^/  /'
    return 1
  fi

  local start_line end_line indent
  start_line=$(grep -n "# @nixup:$hook\$" "$file" | cut -d: -f1)
  end_line=$(awk "NR>$start_line && /# @nixup:end/{print NR; exit}" "$file")
  indent=$(sed -n "${start_line}p" "$file" | sed 's/\(^[[:space:]]*\).*/\1/')

  # Delete lines between start and end (exclusive), then insert new value
  sed -i "$((start_line+1)),$((end_line-1))d" "$file"
  sed -i "${start_line}a\\${indent}$value" "$file"

  print_success "Set '$hook' to '$value'"
  alejandra -q "$file" 2>/dev/null || true
}

config_get() {
  local hook="$1"
  local file
  file=$(find_hook_file "$hook")
  [[ -z "$file" ]] && return 1
  get_hook_items "$hook" | head -1
}

config_list() {
  local hook="${1:-}"

  if [[ -n "$hook" ]]; then
    local file
    file=$(find_hook_file "$hook")
    [[ -z "$file" ]] && { print_error "Hook '$hook' not found"; return 1; }

    echo -e "${BOLD}Items in '$hook':${NC}"
    echo -e "${CYAN}File:${NC} ${file#"$CONFIG_DIR/"}"
    echo ""
    get_hook_items "$hook" | while read -r item; do echo "  $item"; done
  else
    echo -e "${BOLD}Available hooks:${NC}"
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
      printf "  ${CYAN}%-20s${NC} %3d items  ${BLUE}%s${NC}\n" "$h" "$count" "${file#"$CONFIG_DIR/"}"
    done
  fi
}

config_init() {
  local file="$1"
  local hook="$2"
  [[ ! "$file" = /* ]] && file="$CONFIG_DIR/$file"
  [[ ! -f "$file" ]] && { print_error "File not found: $file"; return 1; }
  grep -q "# @nixup:$hook\$" "$file" && { print_warn "Hook already exists"; return 0; }

  echo ""
  echo -e "${BOLD}Hook template:${NC}"
  echo "  # @nixup:$hook"
  echo "  # @nixup:end"
  echo ""
  echo "Add this to your .nix file inside [ ] or { }"
}
