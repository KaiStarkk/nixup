# nixup

Package update checker for NixOS. Equivalent to `pacman -Qu`.

## Problem

NixOS lacks a quick way to see outdated packages. `nixos-rebuild dry-run --upgrade` only shows derivation changes, not version bumps.

## Solution

1. Evaluates nixpkgs once → local index (~17MB, ~5s)
2. Scans installed packages from system closure
3. Instant local lookups (no API)

```
$ nixup list

Updates available (63):
  claude-code: 2.0.47 → 2.0.50
  curl: 8.16.0 → 8.17.0
  systemd: 258.1 → 258.2
```

## Installation

### Flake

```nix
{
  inputs.nixup.url = "github:KaiStarkk/nixup";
}
```

### Home Manager Module

```nix
{
  imports = [inputs.nixup.homeManagerModules.default];
  services.nixup.enable = true;
}
```

### Direct

```bash
nix run github:KaiStarkk/nixup -- list
```

## Usage

```
Commands:
  check       Check for updates (default)
  count       Update count only (for status bars)
  json        Full JSON output
  list        Human-readable list
  installed   Show detected packages

Options:
  --rescan    Force rescan installed packages
  --recheck   Force recheck versions
  --refresh   Force both
  --fetch     Force re-fetch nixpkgs index
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NIX_UPDATE_CACHE_AGE` | `21600` | Cache validity (seconds) |
| `NIX_UPDATE_NIXPKGS_REF` | `github:nixos/nixpkgs/nixos-unstable` | Nixpkgs reference |
| `NIX_UPDATE_SYSTEM_PATH` | `/run/current-system` | System path to scan |
| `NIX_UPDATE_EXCLUDE` | *(build deps)* | Exclusion patterns |

```bash
# Use stable channel
NIX_UPDATE_NIXPKGS_REF="github:nixos/nixpkgs/nixos-24.11" nixup list
```

## Status Bar

Works with HyprPanel, Waybar, Polybar:

```bash
nixup count  # outputs: 63
```

Includes `nix-update-popup` for GTK dialog (yad/zenity).

## License

MIT
