#!/usr/bin/env bash
# option.sh - Read and write NixOS/Home Manager options
# Implements: nixup get, nixup set

# =============================================================================
# nixup get - Read current option value
# =============================================================================

option_get() {
  local option="$1"
  local scope="${2:-system}"  # system or home

  if [[ -z "$option" ]]; then
    print_error "Usage: nixup get <option> [system|home]"
    return 1
  fi

  # Determine which configuration to evaluate
  local flake_attr
  case "$scope" in
    system|nixos)
      local hostname
      hostname=$(hostname)
      flake_attr=".#nixosConfigurations.${hostname}.config.${option}"
      ;;
    home|hm)
      local username
      username=$(whoami)
      local hostname
      hostname=$(hostname)
      flake_attr=".#nixosConfigurations.${hostname}.config.home-manager.users.${username}.${option}"
      ;;
    *)
      print_error "Unknown scope: $scope (use 'system' or 'home')"
      return 1
      ;;
  esac

  echo -e "${BOLD}Getting:${NC} ${CYAN}${option}${NC} (${scope})"
  echo ""

  # Evaluate from within the config directory
  local result
  result=$(cd "$CONFIG_DIR" && nix eval --json "${flake_attr}" 2>&1)
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    echo "$result" | jq -r '.' 2>/dev/null || echo "$result"
    return 0
  else
    # Try raw output for non-JSON types
    result=$(cd "$CONFIG_DIR" && nix eval --raw "${flake_attr}" 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
      echo "$result"
      return 0
    else
      print_error "Could not evaluate option: $option"
      echo ""
      echo "Tried: nix eval --json ${flake_attr}"
      echo "Error: $result"
      return 1
    fi
  fi
}

# =============================================================================
# nixup set - Write option value to config
# =============================================================================

option_set() {
  local option="$1"
  local value="$2"

  if [[ -z "$option" || -z "$value" ]]; then
    print_error "Usage: nixup set <option> <value>"
    return 1
  fi

  # Find the file that owns this option
  local file
  file=$(find_option_file "$option")

  if [[ -z "$file" ]]; then
    print_error "No mapping found for option: $option"
    echo ""
    echo "Add a mapping to schema.yaml or use 'nixup config' for hook-based items"
    return 1
  fi

  local full_path="${CONFIG_DIR}/${file}"

  if [[ ! -f "$full_path" ]]; then
    print_error "File not found: $file"
    echo "You may need to create this file first"
    return 1
  fi

  echo -e "${BOLD}Setting:${NC} ${CYAN}${option}${NC} = ${value}"
  echo -e "${BOLD}File:${NC} ${BLUE}${file}${NC}"
  echo ""

  # Parse the option path
  local option_parts
  IFS='.' read -ra option_parts <<< "$option"
  local option_leaf="${option_parts[-1]}"

  # Check if option already exists in file
  if grep -q "${option_leaf}" "$full_path" 2>/dev/null; then
    echo "Option found in file. Attempting to update..."

    # Simple regex replacement for common patterns
    # This handles: "option = value;" and "option.subopt = value;"
    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')

    # Try to find and replace the option
    if sed -i "s/\(${option_leaf}[[:space:]]*=[[:space:]]*\)[^;]*/\1${escaped_value}/" "$full_path" 2>/dev/null; then
      alejandra -q "$full_path" 2>/dev/null || true
      print_success "Updated ${option_leaf} in ${file}"
    else
      print_error "Could not update option. Manual edit may be required."
      return 1
    fi
  else
    echo "Option not found in file."
    echo ""
    echo -e "${YELLOW}To add this option, insert the following in ${file}:${NC}"
    echo ""

    # Generate the nested Nix structure
    local nix_path=""
    for ((i=0; i<${#option_parts[@]}-1; i++)); do
      nix_path+="${option_parts[$i]}."
    done
    nix_path="${nix_path%.}"

    if [[ -n "$nix_path" ]]; then
      echo "  ${nix_path}.${option_leaf} = ${value};"
    else
      echo "  ${option_leaf} = ${value};"
    fi
    echo ""
    echo "Or use nested blocks:"
    echo ""

    # Generate nested block structure
    local indent="  "
    for part in "${option_parts[@]:0:${#option_parts[@]}-1}"; do
      echo "${indent}${part} = {"
      indent+="  "
    done
    echo "${indent}${option_leaf} = ${value};"
    for ((i=${#option_parts[@]}-2; i>=0; i--)); do
      indent="${indent:2}"
      echo "${indent}};"
    done

    return 1
  fi
}

# =============================================================================
# nixup list - List options in a file or under a prefix
# =============================================================================

option_list() {
  local prefix="$1"

  if [[ -z "$prefix" ]]; then
    print_error "Usage: nixup list <option-prefix>"
    echo "Example: nixup list boot"
    return 1
  fi

  echo -e "${BOLD}Options under:${NC} ${CYAN}${prefix}${NC}"
  echo ""

  # Find the file
  local file
  file=$(find_option_file "${prefix}.*" 2>/dev/null || find_option_file "$prefix" 2>/dev/null)

  if [[ -n "$file" ]]; then
    echo -e "${BOLD}Mapped to:${NC} ${BLUE}${file}${NC}"
    echo ""

    local full_path="${CONFIG_DIR}/${file}"
    if [[ -f "$full_path" ]]; then
      # Extract option assignments from the file
      grep -E '^\s+[a-zA-Z].*=' "$full_path" | \
        sed 's/^[[:space:]]*/  /' | \
        head -30
    fi
  else
    print_error "No mapping found for: $prefix"
  fi
}
