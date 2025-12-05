#!/usr/bin/env bash
# generate.sh - Config generation, migration, and validation
# Implements: nixup init, nixup generate, nixup migrate, nixup validate

# =============================================================================
# nixup init - Create canonical config structure
# =============================================================================

generate_init() {
  local target_dir="${1:-./nixos-config}"

  if [[ -d "$target_dir" ]]; then
    print_error "Directory already exists: $target_dir"
    return 1
  fi

  echo -e "${BOLD}Creating nixup-compatible NixOS config at:${NC} $target_dir"
  echo ""

  # Create directory structure
  mkdir -p "$target_dir"/{system/modules,system/hosts,home/users,scripts,secrets}

  # Create flake.nix template
  cat > "$target_dir/flake.nix" << 'FLAKE'
{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {nixpkgs, home-manager, ...} @ inputs: {
    nixosConfigurations = {
      # Add your host here:
      # hostname = nixpkgs.lib.nixosSystem {
      #   system = "x86_64-linux";
      #   modules = [
      #     ./system/hosts/hostname/default.nix
      #     ./system/modules
      #     home-manager.nixosModules.home-manager
      #     {
      #       home-manager.useGlobalPkgs = true;
      #       home-manager.useUserPackages = true;
      #       home-manager.users.username = import ./home/users/username;
      #     }
      #   ];
      # };
    };
  };
}
FLAKE

  # Create system modules
  cat > "$target_dir/system/modules/default.nix" << 'NIX'
# System modules aggregator
{
  imports = [
    ./boot.nix
    ./locale.nix
    ./hardware.nix
    ./networking.nix
    ./security.nix
    ./services.nix
    ./programs.nix
    ./nix-config.nix
    ./xdg.nix
    ./packages.nix
    ./users.nix
  ];

  system.stateVersion = "24.11"; # Update to your version
}
NIX

  # Create boot.nix
  cat > "$target_dir/system/modules/boot.nix" << 'NIX'
# Boot configuration: boot.*, zramSwap.*, console.*
{
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  zramSwap.enable = true;
}
NIX

  # Create locale.nix
  cat > "$target_dir/system/modules/locale.nix" << 'NIX'
# Locale and time: time.*, i18n.*
{
  time.timeZone = "UTC"; # Change to your timezone

  i18n.defaultLocale = "en_US.UTF-8";
}
NIX

  # Create hardware.nix
  cat > "$target_dir/system/modules/hardware.nix" << 'NIX'
# Hardware configuration: hardware.*, sound.*
{
  hardware = {
    # Add hardware settings here
  };
}
NIX

  # Create networking.nix
  cat > "$target_dir/system/modules/networking.nix" << 'NIX'
# Networking: networking.*, systemd.network.*
{
  networking = {
    networkmanager.enable = true;
    firewall.enable = true;
  };
}
NIX

  # Create security.nix
  cat > "$target_dir/system/modules/security.nix" << 'NIX'
# Security: security.*, pam.*
{
  security = {
    rtkit.enable = true;
    polkit.enable = true;
  };
}
NIX

  # Create services.nix
  cat > "$target_dir/system/modules/services.nix" << 'NIX'
# System services: services.*, systemd.services.*
{
  services = {
    # Add services here
  };
}
NIX

  # Create programs.nix
  cat > "$target_dir/system/modules/programs.nix" << 'NIX'
# System programs: programs.*
{
  programs = {
    # Add programs here
  };
}
NIX

  # Create nix-config.nix
  cat > "$target_dir/system/modules/nix-config.nix" << 'NIX'
# Nix configuration: nix.*, nixpkgs.*
{
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  nixpkgs.config.allowUnfree = true;
}
NIX

  # Create xdg.nix
  cat > "$target_dir/system/modules/xdg.nix" << 'NIX'
# XDG portals: xdg.portal.*
{
  xdg.portal = {
    enable = true;
    # Add portal config here
  };
}
NIX

  # Create packages.nix
  cat > "$target_dir/system/modules/packages.nix" << 'NIX'
# Environment packages: environment.systemPackages
{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    # @nixup:packages
    vim
    git
    curl
    wget
    # @nixup:end
  ];
}
NIX

  # Create users.nix
  cat > "$target_dir/system/modules/users.nix" << 'NIX'
# User configuration: users.*
{
  users.users = {
    # username = {
    #   isNormalUser = true;
    #   extraGroups = ["wheel" "networkmanager"];
    # };
  };
}
NIX

  # Create schema.yaml
  cat > "$target_dir/schema.yaml" << 'YAML'
# nixup Schema - Maps NixOS/Home Manager options to files
version: 1

system:
  boot.*: system/modules/boot.nix
  zramSwap.*: system/modules/boot.nix
  time.*: system/modules/locale.nix
  i18n.*: system/modules/locale.nix
  hardware.*: system/modules/hardware.nix
  networking.*: system/modules/networking.nix
  security.*: system/modules/security.nix
  services.*: system/modules/services.nix
  programs.*: system/modules/programs.nix
  nix.*: system/modules/nix-config.nix
  nixpkgs.*: system/modules/nix-config.nix
  xdg.*: system/modules/xdg.nix
  environment.systemPackages: system/modules/packages.nix
  users.*: system/modules/users.nix

home:
  home.packages: home/users/*/packages.nix
  programs.*: home/users/*/programs.nix
YAML

  # Create .gitignore
  cat > "$target_dir/.gitignore" << 'GITIGNORE'
result
*.qcow2
secrets.yaml
.direnv/
GITIGNORE

  print_success "Created nixup-compatible config structure"
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  1. cd $target_dir"
  echo "  2. Edit flake.nix to add your host"
  echo "  3. Create hardware-configuration.nix: nixos-generate-config --show-hardware-config"
  echo "  4. Run: nixup validate"
}

# =============================================================================
# nixup validate - Check config matches schema
# =============================================================================

generate_validate() {
  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    echo "Run 'nixup init' to create a new config with schema"
    return 1
  fi

  echo -e "${BOLD}Validating config structure...${NC}"
  echo ""

  local errors=0
  local warnings=0

  # Check required files exist
  local required_files=(
    "flake.nix"
    "system/modules/default.nix"
    "schema.yaml"
  )

  for file in "${required_files[@]}"; do
    if [[ ! -f "${CONFIG_DIR}/${file}" ]]; then
      echo -e "  ${RED}error:${NC} Missing required file: $file"
      ((errors++))
    fi
  done

  # Check files mentioned in schema exist
  echo -e "${BOLD}Checking schema file mappings...${NC}"

  local schema_files
  schema_files=$(grep -E ':\s+[a-z]' "$SCHEMA_FILE" | \
    sed 's/.*:\s*//' | \
    sed 's/[[:space:]]*$//' | \
    grep -v '{' | \
    sort -u)

  for file in $schema_files; do
    local full_path="${CONFIG_DIR}/${file}"
    if [[ ! -f "$full_path" && ! -d "$full_path" ]]; then
      echo -e "  ${YELLOW}warning:${NC} Schema references missing file: $file"
      ((warnings++))
    fi
  done

  # Check for nixup hooks in package files
  echo ""
  echo -e "${BOLD}Checking nixup hooks...${NC}"

  local hooks
  hooks=$(find_hooks 2>/dev/null || echo "")

  if [[ -z "$hooks" ]]; then
    echo -e "  ${YELLOW}warning:${NC} No nixup hooks found"
    echo "  Add hooks like: # @nixup:packages ... # @nixup:end"
    ((warnings++))
  else
    local hook_count
    hook_count=$(echo "$hooks" | wc -l)
    echo -e "  ${GREEN}✓${NC} Found $hook_count hooks: $(echo $hooks | tr '\n' ' ')"
  fi

  # Check for common issues
  echo ""
  echo -e "${BOLD}Checking for common issues...${NC}"

  # Check if any .nix files have syntax errors
  local nix_files
  nix_files=$(find "$CONFIG_DIR" -name "*.nix" -type f 2>/dev/null | head -20)

  for file in $nix_files; do
    if ! nix-instantiate --parse "$file" >/dev/null 2>&1; then
      echo -e "  ${RED}error:${NC} Syntax error in: ${file#$CONFIG_DIR/}"
      ((errors++))
    fi
  done

  echo ""
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    print_success "Validation passed - no issues found"
  elif [[ $errors -eq 0 ]]; then
    echo -e "${YELLOW}Validation completed with $warnings warning(s)${NC}"
  else
    echo -e "${RED}Validation failed: $errors error(s), $warnings warning(s)${NC}"
    return 1
  fi
}

# =============================================================================
# nixup migrate - Analyze and suggest migration steps
# =============================================================================

generate_migrate() {
  local source_dir="${1:-$CONFIG_DIR}"

  if [[ ! -d "$source_dir" ]]; then
    print_error "Directory not found: $source_dir"
    return 1
  fi

  echo -e "${BOLD}Analyzing config for migration...${NC}"
  echo ""

  # Find all .nix files
  local nix_files
  nix_files=$(find "$source_dir" -name "*.nix" -type f | grep -v result | sort)

  local total_files
  total_files=$(echo "$nix_files" | wc -l)
  echo "Found $total_files Nix files"
  echo ""

  # Analyze file sizes and complexity
  echo -e "${BOLD}Large files (potential refactoring candidates):${NC}"

  for file in $nix_files; do
    local lines
    lines=$(wc -l < "$file")
    if [[ $lines -gt 100 ]]; then
      local rel_file="${file#$source_dir/}"
      printf "  ${YELLOW}%-50s${NC} %4d lines\n" "$rel_file" "$lines"
    fi
  done

  echo ""
  echo -e "${BOLD}Migration recommendations:${NC}"
  echo ""

  # Check for monolithic files
  if [[ -f "$source_dir/configuration.nix" ]]; then
    echo "  1. Split configuration.nix into:"
    echo "     - system/modules/boot.nix"
    echo "     - system/modules/hardware.nix"
    echo "     - system/modules/networking.nix"
    echo "     - system/modules/services.nix"
    echo "     - etc."
    echo ""
  fi

  # Check for home-manager
  if grep -rq "home-manager" "$source_dir" 2>/dev/null; then
    echo "  2. Home Manager detected - consider splitting user config into:"
    echo "     - home/users/<username>/packages/*.nix"
    echo "     - home/users/<username>/programs/*.nix"
    echo ""
  fi

  # Check for missing schema
  if [[ ! -f "$source_dir/schema.yaml" ]]; then
    echo "  3. Add schema.yaml for nixup option mapping"
    echo "     Run: nixup init --schema-only (in existing config)"
    echo ""
  fi

  # Check for nixup hooks
  if ! grep -rq "@nixup:" "$source_dir" 2>/dev/null; then
    echo "  4. Add nixup hooks for package management:"
    echo "     # @nixup:packages"
    echo "     package1"
    echo "     package2"
    echo "     # @nixup:end"
    echo ""
  fi

  echo -e "${BOLD}To start migration:${NC}"
  echo "  1. Create canonical directory structure"
  echo "  2. Move options to appropriate files per schema"
  echo "  3. Add nixup hooks where needed"
  echo "  4. Run: nixup validate"
}

# =============================================================================
# nixup diff system - Compare declared vs running config
# =============================================================================

generate_diff_system() {
  local option="${1:-}"

  echo -e "${BOLD}Comparing declared vs running system...${NC}"
  echo ""

  if [[ -n "$option" ]]; then
    # Compare specific option
    local declared running

    echo -e "${CYAN}Option:${NC} $option"
    echo ""

    # Get declared value
    declared=$(cd "$CONFIG_DIR" && nix eval --json ".#nixosConfigurations.$(hostname).config.${option}" 2>/dev/null || echo "null")

    # Get running value (if applicable)
    # This is tricky - some options map to files, some to systemd, etc.
    # For now, show just the declared value

    echo -e "${BOLD}Declared:${NC}"
    echo "$declared" | jq -r '.' 2>/dev/null || echo "$declared"
  else
    # Show summary of key differences
    echo "Comparing key system attributes..."
    echo ""

    # Check kernel version
    local declared_kernel running_kernel
    declared_kernel=$(cd "$CONFIG_DIR" && nix eval --raw ".#nixosConfigurations.$(hostname).config.boot.kernelPackages.kernel.version" 2>/dev/null || echo "?")
    running_kernel=$(uname -r | cut -d- -f1)

    printf "  %-30s declared: %-15s running: %s\n" "Kernel version" "$declared_kernel" "$running_kernel"

    # Check NixOS version
    local declared_version running_version
    declared_version=$(cd "$CONFIG_DIR" && nix eval --raw ".#nixosConfigurations.$(hostname).config.system.nixos.version" 2>/dev/null || echo "?")
    running_version=$(nixos-version 2>/dev/null | cut -d. -f1-2 || echo "?")

    printf "  %-30s declared: %-15s running: %s\n" "NixOS version" "$declared_version" "$running_version"

    # Check timezone
    local declared_tz running_tz
    declared_tz=$(cd "$CONFIG_DIR" && nix eval --raw ".#nixosConfigurations.$(hostname).config.time.timeZone" 2>/dev/null || echo "?")
    running_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")

    printf "  %-30s declared: %-15s running: %s\n" "Timezone" "$declared_tz" "$running_tz"

    echo ""
    echo "Run 'nixup diff system <option>' to compare a specific option"
  fi
}

# =============================================================================
# nixup generate - Generate config from evaluation (advanced)
# =============================================================================

generate_from_eval() {
  echo -e "${BOLD}Generating config from evaluation...${NC}"
  echo ""
  echo -e "${YELLOW}Note:${NC} This is an experimental feature."
  echo ""

  # This would require parsing nix eval output and generating Nix code
  # For now, show what could be done

  echo "This command would:"
  echo "  1. Evaluate the current NixOS configuration"
  echo "  2. Extract all set options"
  echo "  3. Generate canonical Nix files based on schema"
  echo ""
  echo "For now, use:"
  echo "  - 'nixup migrate' to analyze existing config"
  echo "  - 'nixup init' to create new canonical structure"
  echo "  - Manual refactoring guided by schema.yaml"
}
