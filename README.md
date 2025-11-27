# nixup

Unified NixOS management tool for **updates**, **configuration**, and **dotfiles**.

## Features

### 📦 Updates - Package Update Checking
Fast package update detection. Equivalent to `pacman -Qu` for NixOS.

- Evaluates nixpkgs once → local index (~17MB, ~5s)
- Scans installed packages from system closure
- Instant local lookups (no API calls)
- Status bar integration

### ⚙️  Config - Configuration Management
Hook-based declarative config management from the CLI.

- Add/remove packages without editing files
- Search nixpkgs
- Auto-format with alejandra
- Portable - works with any NixOS config

### 📄 Diff - Dotfile Backup Management
Track and restore Home Manager dotfile overwrites.

- List backed up dotfiles
- Restore previous versions
- Compare changes

## Installation

### As a Flake Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixup.url = "github:KaiStarkk/nixup";
  };

  outputs = { nixpkgs, nixup, ... }: {
    nixosConfigurations.hostname = nixpkgs.lib.nixosSystem {
      modules = [{
        environment.systemPackages = [ nixup.packages.x86_64-linux.default ];
      }];
    };
  };
}
```

### Try Without Installing

```bash
nix run github:KaiStarkk/nixup -- updates list
nix run github:KaiStarkk/nixup -- config --help
```

## Usage

### Updates

```bash
# Check for updates
nixup updates list

# Get update count (for status bars)
nixup updates count

# Force refresh
nixup updates fetch --refresh
```

Example output:
```
Updates available (63):
  claude-code: 2.0.47 → 2.0.50
  curl: 8.16.0 → 8.17.0
  systemd: 258.1 → 258.2
```

### Config Management

First, add hook markers to your .nix files:

```nix
home.packages = with pkgs; [
  # @nixup:packages
  # @nixup:end

  # manually managed packages below
  wget
  curl
];
```

Then manage them from the CLI:

```bash
# Add packages
nixup config add packages ghq
nixup config add packages gita

# List all hooks
nixup config list

# List items in a hook
nixup config list packages

# Remove packages
nixup config rm packages ghq

# Search before adding
nixup config search lazygit

# Format all .nix files
nixup config format
```

### Dotfile Management

If you configure Home Manager to backup files it overwrites, nixup helps you manage them.

First, configure Home Manager to use a backup directory:
```nix
home.file.".config/kitty/kitty.conf" = {
  source = ./kitty.conf;
  force = true;
};

# Enable backups for all managed files
home.backupFileExtension = "backup";
```

Or set a custom backup directory in your Home Manager config. Then manage backups:

```bash
# List backed up dotfiles
nixup diff list

# Restore a dotfile
nixup diff restore kitty/kitty.conf

# Show diff (for manual merge)
nixup diff restore kitty/kitty.conf --merge

# Clear all backups
nixup diff clear
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NIXUP_CONFIG_DIR` | `~/code/nixos-config` | Config directory |
| `NIX_UPDATE_CACHE_AGE` | `21600` (6h) | Cache validity (seconds) |
| `NIX_UPDATE_NIXPKGS_REF` | `github:nixos/nixpkgs/nixos-unstable` | Nixpkgs reference |
| `NIX_UPDATE_SYSTEM_PATH` | `/run/current-system` | System path to scan |

Example:
```bash
# Use stable channel for update checks
NIX_UPDATE_NIXPKGS_REF="github:nixos/nixpkgs/nixos-24.11" nixup updates list

# Use different config directory
NIXUP_CONFIG_DIR=~/my-nixos-config nixup config list
```

## Status Bar Integration

Works with HyprPanel, Waybar, Polybar, etc:

```bash
nixup updates count    # outputs: 63 (or ? during refresh)
nixup updates tooltip  # formatted tooltip with package list
nixup updates open     # opens terminal with update list (uses $TERMINAL)
```

Tooltip output:
```
# updates available
- hyprbars 0.1 → 0.52.0
- qtbase 5.15.18 → 6.10.1
... and 4 others
```

During refresh, tooltip shows progress:
```
# refreshing
████░░░░░░ (250/500)
```

Waybar example:
```json
{
  "custom/updates": {
    "exec": "nixup updates count",
    "exec-on-event": false,
    "interval": 3600,
    "format": " {}",
    "tooltip-exec": "nixup updates tooltip",
    "on-click": "nixup updates open"
  }
}
```

## How It Works

**Updates**: Evaluates nixpkgs once to build a local index, then compares installed packages with instant lookups. No network calls during comparison.

**Config**: Uses simple comment markers (`# @nixup:<hook-name> ... # @nixup:end`) to identify manageable sections. Changes are made in-place and formatted with alejandra.

**Diff**: Monitors Home Manager's backup directory (`~/.config-backups/`) and provides commands to view and restore previous versions.

## License

MIT
