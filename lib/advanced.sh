#!/usr/bin/env bash
# advanced.sh - Phase 4: Host, Service, Theme, and Profile management
# Implements: nixup host, nixup service, nixup theme, nixup profile

# =============================================================================
# HOST MANAGEMENT
# =============================================================================

host_list() {
  echo -e "${BOLD}Available hosts:${NC}"
  echo ""

  local hosts_dir="${CONFIG_DIR}/system/hosts"
  if [[ ! -d "$hosts_dir" ]]; then
    print_warn "No hosts directory found at $hosts_dir"
    return 0
  fi

  local current_host
  current_host=$(hostname)

  for host_dir in "$hosts_dir"/*/; do
    [[ -d "$host_dir" ]] || continue
    local host_name
    host_name=$(basename "$host_dir")

    if [[ "$host_name" == "$current_host" ]]; then
      echo -e "  ${GREEN}●${NC} ${BOLD}$host_name${NC} (current)"
    else
      echo -e "  ${CYAN}○${NC} $host_name"
    fi

    # Show hardware summary if available
    if [[ -f "${host_dir}/hardware-configuration.nix" ]]; then
      local fs_count
      fs_count=$(grep -c "fileSystems\." "${host_dir}/hardware-configuration.nix" 2>/dev/null || echo "0")
      echo "      filesystems: $fs_count"
    fi
  done
}

host_add() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup host add <hostname>"
    return 1
  fi

  local host_dir="${CONFIG_DIR}/system/hosts/${name}"

  if [[ -d "$host_dir" ]]; then
    print_error "Host already exists: $name"
    return 1
  fi

  echo -e "${BOLD}Creating host:${NC} $name"

  mkdir -p "$host_dir"

  # Create default.nix
  cat > "${host_dir}/default.nix" << NIX
# Host-specific configuration for ${name}
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "${name}";

  # Host-specific settings go here
}
NIX

  # Create placeholder hardware-configuration.nix
  cat > "${host_dir}/hardware-configuration.nix" << 'NIX'
# Hardware configuration - generate with:
# nixos-generate-config --show-hardware-config > hardware-configuration.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # TODO: Run nixos-generate-config and replace this file
  boot.initrd.availableKernelModules = [];
  boot.kernelModules = [];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
NIX

  print_success "Created host: $name"
  echo ""
  echo "Next steps:"
  echo "  1. Generate hardware config: nixos-generate-config --show-hardware-config"
  echo "  2. Copy to: ${host_dir}/hardware-configuration.nix"
  echo "  3. Add host to flake.nix nixosConfigurations"
  echo "  4. Customize ${host_dir}/default.nix"
}

host_get() {
  local host="$1"
  local option="$2"

  if [[ -z "$host" || -z "$option" ]]; then
    print_error "Usage: nixup host get <hostname> <option>"
    return 1
  fi

  echo -e "${BOLD}Getting:${NC} ${CYAN}${option}${NC} for host ${YELLOW}${host}${NC}"
  echo ""

  local result
  result=$(cd "$CONFIG_DIR" && nix eval --json ".#nixosConfigurations.${host}.config.${option}" 2>&1)

  if [[ $? -eq 0 ]]; then
    echo "$result" | jq -r '.' 2>/dev/null || echo "$result"
  else
    print_error "Could not evaluate: $result"
    return 1
  fi
}

host_set() {
  local host="$1"
  local option="$2"
  local value="$3"

  if [[ -z "$host" || -z "$option" || -z "$value" ]]; then
    print_error "Usage: nixup host set <hostname> <option> <value>"
    return 1
  fi

  local host_file="${CONFIG_DIR}/system/hosts/${host}/default.nix"

  if [[ ! -f "$host_file" ]]; then
    print_error "Host config not found: $host_file"
    return 1
  fi

  echo -e "${BOLD}Setting:${NC} ${CYAN}${option}${NC} = ${value} for host ${YELLOW}${host}${NC}"
  echo ""
  echo "Manual edit required in: $host_file"
  echo ""
  echo "Add this line:"
  echo "  ${option} = ${value};"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

service_list() {
  local scope="${1:-system}"

  echo -e "${BOLD}Enabled services (${scope}):${NC}"
  echo ""

  if [[ "$scope" == "system" ]]; then
    # List system services
    cd "$CONFIG_DIR" && nix eval --json ".#nixosConfigurations.$(hostname).config.services" 2>/dev/null | \
      jq -r 'to_entries | .[] | select(.value.enable? == true) | .key' 2>/dev/null | \
      sort | while read -r svc; do
        echo -e "  ${GREEN}●${NC} $svc"
      done
  else
    # List user services
    cd "$CONFIG_DIR" && nix eval --json ".#nixosConfigurations.$(hostname).config.home-manager.users.$(whoami).services" 2>/dev/null | \
      jq -r 'to_entries | .[] | select(.value.enable? == true) | .key' 2>/dev/null | \
      sort | while read -r svc; do
        echo -e "  ${GREEN}●${NC} $svc"
      done
  fi
}

service_enable() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup service enable <service-name>"
    return 1
  fi

  # Find the services file
  local services_file="${CONFIG_DIR}/system/modules/services.nix"

  echo -e "${BOLD}To enable service:${NC} $name"
  echo ""
  echo "Add to $services_file:"
  echo ""
  echo "  services.${name}.enable = true;"
  echo ""
  echo "Or for Home Manager services, add to home/users/*/services.nix:"
  echo ""
  echo "  services.${name}.enable = true;"
}

service_disable() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup service disable <service-name>"
    return 1
  fi

  echo -e "${BOLD}To disable service:${NC} $name"
  echo ""
  echo "Set in the appropriate services file:"
  echo ""
  echo "  services.${name}.enable = false;"
  echo ""
  echo "Or remove/comment out the service configuration."
}

service_config() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup service config <service-name>"
    return 1
  fi

  echo -e "${BOLD}Configuration for service:${NC} $name"
  echo ""

  local result
  result=$(cd "$CONFIG_DIR" && nix eval --json ".#nixosConfigurations.$(hostname).config.services.${name}" 2>&1)

  if [[ $? -eq 0 ]]; then
    echo "$result" | jq -r '.' 2>/dev/null || echo "$result"
  else
    print_error "Service not found or not configured: $name"
    echo ""
    echo "Check available options with: man configuration.nix"
    echo "Or search: nixos-option services.${name}"
  fi
}

# =============================================================================
# THEME MANAGEMENT
# =============================================================================

theme_list() {
  echo -e "${BOLD}Available themes:${NC}"
  echo ""

  # Check if stylix is configured
  local stylix_file="${CONFIG_DIR}/system/modules/theming.nix"

  if [[ -f "$stylix_file" ]]; then
    echo "Stylix themes (base16):"
    echo ""

    # Try to list available schemes
    if command -v nix &>/dev/null; then
      # Get current theme
      local current
      current=$(grep -o 'base16Scheme = "[^"]*"' "$stylix_file" 2>/dev/null | cut -d'"' -f2 || echo "")

      # Common base16 schemes
      local schemes=(
        "rose-pine" "rose-pine-moon" "rose-pine-dawn"
        "gruvbox-dark-medium" "gruvbox-light-medium"
        "catppuccin-mocha" "catppuccin-latte" "catppuccin-frappe" "catppuccin-macchiato"
        "dracula" "nord" "solarized-dark" "solarized-light"
        "tokyo-night-dark" "tokyo-night-storm" "one-dark"
      )

      for scheme in "${schemes[@]}"; do
        if [[ "$scheme" == "$current" ]]; then
          echo -e "  ${GREEN}●${NC} ${BOLD}$scheme${NC} (current)"
        else
          echo -e "  ${CYAN}○${NC} $scheme"
        fi
      done

      echo ""
      echo "More schemes: https://github.com/tinted-theming/schemes"
    fi
  else
    print_warn "Stylix theming not configured"
    echo "Add theming.nix with stylix configuration"
  fi
}

theme_get() {
  echo -e "${BOLD}Current theme:${NC}"
  echo ""

  local stylix_file="${CONFIG_DIR}/system/modules/theming.nix"

  if [[ -f "$stylix_file" ]]; then
    local scheme polarity
    scheme=$(grep -o 'base16Scheme = [^;]*' "$stylix_file" 2>/dev/null | head -1 || echo "not set")
    polarity=$(grep -o 'polarity = "[^"]*"' "$stylix_file" 2>/dev/null | cut -d'"' -f2 || echo "not set")

    echo "  Scheme: $scheme"
    echo "  Polarity: $polarity"

    # Get fonts if configured
    echo ""
    echo -e "${BOLD}Fonts:${NC}"
    grep -A2 "fonts\." "$stylix_file" 2>/dev/null | head -10 | sed 's/^/  /'
  else
    print_warn "Theming file not found"
  fi
}

theme_set() {
  local scheme="$1"

  if [[ -z "$scheme" ]]; then
    print_error "Usage: nixup theme set <scheme-name>"
    echo "Run 'nixup theme list' to see available schemes"
    return 1
  fi

  local stylix_file="${CONFIG_DIR}/system/modules/theming.nix"

  echo -e "${BOLD}To set theme:${NC} $scheme"
  echo ""

  if [[ -f "$stylix_file" ]]; then
    echo "Edit $stylix_file and change:"
    echo ""
    echo '  base16Scheme = "${pkgs.base16-schemes}/share/themes/'$scheme'.yaml";'
    echo ""
    echo "Then rebuild: nh os switch"
  else
    echo "Create $stylix_file with:"
    echo ""
    echo '  stylix = {'
    echo '    enable = true;'
    echo '    base16Scheme = "${pkgs.base16-schemes}/share/themes/'$scheme'.yaml";'
    echo '    polarity = "dark";'
    echo '  };'
  fi
}

font_set() {
  local font_type="$1"
  local font_name="$2"

  if [[ -z "$font_type" || -z "$font_name" ]]; then
    print_error "Usage: nixup font set <type> <font-name>"
    echo "Types: mono, sans, serif, emoji"
    return 1
  fi

  echo -e "${BOLD}To set ${font_type} font:${NC} $font_name"
  echo ""
  echo "Edit system/modules/theming.nix:"
  echo ""
  echo "  stylix.fonts.${font_type} = {"
  echo "    package = pkgs.${font_name};"
  echo '    name = "Font Display Name";'
  echo "  };"
}

# =============================================================================
# PROFILE MANAGEMENT
# =============================================================================

profile_list() {
  echo -e "${BOLD}Available profiles:${NC}"
  echo ""

  # Check specialisations
  local theming_file="${CONFIG_DIR}/system/modules/theming.nix"

  if [[ -f "$theming_file" ]] && grep -q "specialisation" "$theming_file"; then
    echo "Specialisations (theme variants):"
    grep -A1 'specialisation\.' "$theming_file" 2>/dev/null | \
      grep -o '"[^"]*"' | tr -d '"' | sort -u | while read -r spec; do
        echo -e "  ${CYAN}○${NC} $spec"
      done
    echo ""
  fi

  # Check for profile files/directories
  local profiles_dir="${CONFIG_DIR}/profiles"
  if [[ -d "$profiles_dir" ]]; then
    echo "Custom profiles:"
    for profile in "$profiles_dir"/*.nix; do
      [[ -f "$profile" ]] || continue
      local name
      name=$(basename "$profile" .nix)
      echo -e "  ${CYAN}○${NC} $name"
    done
  fi

  # Check for optional module patterns
  echo ""
  echo "Common profile patterns:"
  echo "  • gaming     - Steam, gamemode, etc."
  echo "  • latex      - TeX Live, PDF tools"
  echo "  • dev-full   - All development tools"
  echo "  • minimal    - Bare essentials"
}

profile_enable() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup profile enable <profile-name>"
    return 1
  fi

  echo -e "${BOLD}To enable profile:${NC} $name"
  echo ""

  local profiles_dir="${CONFIG_DIR}/profiles"

  if [[ -f "${profiles_dir}/${name}.nix" ]]; then
    echo "Add to your host's default.nix imports:"
    echo ""
    echo "  imports = ["
    echo "    ../../profiles/${name}.nix"
    echo "  ];"
  else
    echo "Profile not found. Create ${profiles_dir}/${name}.nix with:"
    echo ""
    echo "  { pkgs, ... }: {"
    echo "    # Profile-specific configuration"
    echo "  }"
    echo ""
    echo "Then import it in your host config."
  fi
}

profile_disable() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup profile disable <profile-name>"
    return 1
  fi

  echo -e "${BOLD}To disable profile:${NC} $name"
  echo ""
  echo "Remove the import from your host's configuration."
}

profile_create() {
  local name="$1"

  if [[ -z "$name" ]]; then
    print_error "Usage: nixup profile create <profile-name>"
    return 1
  fi

  local profiles_dir="${CONFIG_DIR}/profiles"
  local profile_file="${profiles_dir}/${name}.nix"

  mkdir -p "$profiles_dir"

  if [[ -f "$profile_file" ]]; then
    print_error "Profile already exists: $name"
    return 1
  fi

  cat > "$profile_file" << NIX
# Profile: ${name}
# Enable by importing in host config
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Add profile-specific packages
  environment.systemPackages = with pkgs; [
    # @nixup:${name}
    # @nixup:end
  ];

  # Add profile-specific configuration
}
NIX

  print_success "Created profile: $name"
  echo ""
  echo "File: $profile_file"
  echo ""
  echo "To enable, import in your host config:"
  echo "  imports = [ ../../profiles/${name}.nix ];"
}
