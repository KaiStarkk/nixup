#!/usr/bin/env bash
# diff.sh - Dotfile backup management (list, restore, clear)

# =============================================================================
# Diff management
# =============================================================================

diff_list() {
  [[ ! -d "$BACKUP_DIR" ]] && { echo "No backups found"; return 0; }

  echo -e "${BOLD}Backed up dotfiles:${NC}"
  find "$BACKUP_DIR" -type f -name "*.backup.*" 2>/dev/null | \
    sed 's|.backup.[0-9]*$||' | sort -u | while read -r base; do
      local latest
      latest=$(find "$BACKUP_DIR" -name "$(basename "$base").backup.*" -path "*$base.backup.*" 2>/dev/null | sort -r | head -1)
      [[ -z "$latest" ]] && continue

      local rel="${latest#"$BACKUP_DIR"/}"
      local orig="${rel%.backup.*}"
      local ts="${rel##*.backup.}"

      if [[ "$ts" =~ ^[0-9]{14}$ ]]; then
        ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
      fi

      echo "  ${CYAN}$orig${NC} ($ts)"
    done
}

diff_restore() {
  local file="${1:-}"
  local merge="${2:-}"

  [[ -z "$file" ]] && { print_error "Usage: nixup diff restore <dotfile> [--merge]"; return 1; }

  local latest
  latest=$(find "$BACKUP_DIR" -name "$(basename "$file").backup.*" 2>/dev/null | sort -r | head -1)
  [[ -z "$latest" ]] && { print_error "No backup found for $file"; return 1; }

  local XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  local XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  local target=""

  [[ -f "$XDG_CONFIG_HOME/$file" ]] && target="$XDG_CONFIG_HOME/$file"
  [[ -z "$target" && -f "$XDG_DATA_HOME/$file" ]] && target="$XDG_DATA_HOME/$file"
  [[ -z "$target" ]] && { print_error "Cannot find $file"; return 1; }

  if [[ "$merge" == "--merge" ]]; then
    # Merge: restore backup AND update nix config source
    print_info "Showing diff (- = backup/your changes, + = nix config):"
    diff -u "$latest" "$target" || true
    echo ""

    # Restore to runtime location
    cp "$latest" "$target"
    print_success "Restored $file"

    # Find and update the source file in nix config
    local basename_file
    basename_file=$(basename "$file")
    local source_file
    source_file=$(find "$CONFIG_DIR" -type f -name "$basename_file" 2>/dev/null | grep -v '.backup' | head -1)

    if [[ -n "$source_file" ]]; then
      cp "$latest" "$source_file"
      print_success "Updated nix config: ${source_file#"$CONFIG_DIR/"}"
      print_info "Run nixos-rebuild to apply permanently"
    else
      print_warn "Could not find source file in $CONFIG_DIR"
      print_warn "Manually copy your changes to persist them"
    fi
  else
    # Default: just show diff
    print_info "Showing diff (- = backup/your changes, + = nix config):"
    diff -u "$latest" "$target" || true
    echo ""
    print_warn "Backup: $latest"
    print_warn "Current: $target"
    echo ""
    print_info "Use --merge to restore backup and update nix config"
  fi
}

diff_clear() {
  [[ ! -d "$BACKUP_DIR" ]] && { print_info "No backups"; return 0; }
  local count
  count=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
  [[ "$count" -eq 0 ]] && { print_info "No backups"; return 0; }

  echo -e "${YELLOW}Warning:${NC} Delete $count backup(s)?"
  read -r -p "Confirm [y/N]: " response
  [[ "$response" =~ ^[Yy]$ ]] && { rm -rf "$BACKUP_DIR"; print_success "Cleared backups"; } || echo "Cancelled"
}
