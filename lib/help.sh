#!/usr/bin/env bash
# help.sh - Help text and dotfiles setup documentation

# =============================================================================
# Help
# =============================================================================

usage() {
  cat <<EOF
${BOLD}nixup${NC} - NixOS Management Tool

${BOLD}USAGE:${NC}
    nixup <subcommand> [options...]

${BOLD}SUBCOMMANDS:${NC}

  ${CYAN}updates${NC} - Package update checking
    count             Output update count (󰑓 during refresh)
    tooltip           Status bar tooltip (progress when busy, updates when idle)
    fetch             Refresh package data in background
    list              Show available updates interactively
    open              Open terminal with update list (left-click action)

  ${CYAN}mode${NC} - Filter mode for updates display
    get               Show current filter mode name
    set <0-3>         Set filter mode by number
    cycle [up|down]   Cycle to next/previous mode
    list              List all available modes

    ${BOLD}Modes:${NC}
      0 - Packages      Only packages explicitly in config files
      1 - +Programs     Packages plus programs.*.enable entries
      2 - All (ex.)     All packages except system/build deps
      3 - All (verbose) Everything including system packages

  ${CYAN}config${NC} - Configuration management
    list [hook]       List all hooks or items in a hook
    add <hook> <item> Add item to a config hook
    rm <hook> <item>  Remove item from a config hook
    set <hook> <value> Set value for a config hook
    get <hook>        Get value from a config hook
    init <file> <hook> Initialize a new hook point

  ${CYAN}diff${NC} - Dotfile backup and system comparison
    list              List all backed up dotfiles
    restore <file>    Restore a backed up dotfile
    clear             Remove all backups
    system [option]   Compare declared vs running system config

  ${CYAN}dotfiles${NC} - Dotfile configuration help
    setup             Show how to set up managed dotfiles

  ${CYAN}init${NC} [path] - Create new nixup-compatible config
    Creates canonical directory structure with schema.yaml
    Default path: ./nixos-config

  ${CYAN}validate${NC} - Check config structure matches schema
    Verifies required files exist and hooks are present

  ${CYAN}migrate${NC} [path] - Analyze config for migration
    Suggests refactoring steps for existing configs

  ${CYAN}generate${NC} - Generate config from evaluation (experimental)
    Regenerate files based on current option values

  ${CYAN}schema${NC} - View option-to-file mappings
    (no arg)          Show full canonical file structure
    <filter>          Filter by pattern (e.g., 'boot', 'programs')
    tree              Show as file tree with option counts
    validate          Check schema against actual filesystem

  ${CYAN}where${NC} <option> - Find which file owns a NixOS/HM option
    Examples:
      nixup where boot.loader.systemd-boot.enable
      nixup where programs.kitty.settings

  ${CYAN}get${NC} <option> [scope] - Read current option value from config
    scope: 'system' (default) or 'home'
    Examples:
      nixup get boot.loader.systemd-boot.enable
      nixup get programs.fish.enable home

  ${CYAN}set${NC} <option> <value> - Set option value in config file
    Examples:
      nixup set boot.plymouth.enable true
      nixup set time.timeZone '"America/New_York"'

  ${CYAN}list${NC} <prefix> - List options under a prefix
    Examples:
      nixup list boot
      nixup list programs.kitty

${BOLD}EXAMPLES:${NC}
    nixup updates count      # For status bar text
    nixup updates tooltip    # For status bar tooltip
    nixup mode cycle up      # Switch to next filter mode
    nixup config add packages ghq
    nixup config list

${BOLD}ENVIRONMENT:${NC}
    NIXUP_CONFIG_DIR     Config directory (default: ~/code/github.com/KaiStarkk/nixos-config)
    NIX_UPDATE_CACHE_AGE Cache validity (default: 21600s = 6h)
EOF
}

# =============================================================================
# Dotfiles setup guide
# =============================================================================

dotfiles_setup() {
  cat <<'SETUPEOF'
DOTFILE MANAGEMENT WITH NIXUP
=============================

nixup's diff commands (list, restore, clear) work with dotfiles that are
backed up to ~/.config-backups/. There are two approaches:


1. IMMUTABLE DOTFILES (fully managed by Nix)
--------------------------------------------
For files you never want to edit manually, use xdg.configFile:

  xdg.configFile."myapp/config.json".text = builtins.toJSON {
    setting = "value";
  };

  # Or from a file:
  xdg.configFile."myapp/config.ini".source = ./myapp/config.ini;

Home Manager will overwrite these on each rebuild.


2. MUTABLE DOTFILES (with change detection)
-------------------------------------------
For files you might edit (like editor settings), add this helper to your
Home Manager config (e.g., in a let block):

  smartWriteConfig = relPath: content:
    lib.hm.dag.entryAfter ["writeBoundary"] ''
      BACKUP_DIR="$HOME/.config-backups"
      target="${XDG_CONFIG_HOME:-$HOME/.config}/${relPath}"
      mkdir -p "$(dirname "$target")"
      mkdir -p "$BACKUP_DIR/$(dirname "${relPath}")"

      new_content=$(cat <<'NIXCONTENT'
${content}
NIXCONTENT
      )

      if [ -f "$target" ]; then
        if [ "$(cat "$target")" != "$new_content" ]; then
          cp "$target" "$BACKUP_DIR/${relPath}.backup.$(date +%Y%m%d%H%M%S)"
        fi
      fi
      printf '%s' "$new_content" > "$target"
    '';

Then use it like:

  home.activation.initEditorSettings =
    smartWriteConfig "myeditor/settings.json"
    (builtins.readFile ./editor/settings.json);


BACKUP DIRECTORY STRUCTURE
--------------------------
Backups are stored at ~/.config-backups/ with timestamps:

  ~/.config-backups/
  +-- myeditor/
  |   +-- settings.json.backup.20241127120530
  +-- otherapp/
      +-- config.json.backup.20241127120530


USING NIXUP DIFF COMMANDS
-------------------------
Once your dotfiles back up to ~/.config-backups/:

  nixup diff list              # See all backed up dotfiles
  nixup diff restore <file>    # Restore a backup
  nixup diff restore <file> --merge   # View diff instead
  nixup diff clear             # Remove all backups

SETUPEOF
}
