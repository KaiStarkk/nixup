#!/usr/bin/env bash
# schema.sh - Schema-based option-to-file mapping
# Implements: nixup schema, nixup where

SCHEMA_FILE="${CONFIG_DIR}/schema.yaml"

# =============================================================================
# Schema parsing helpers
# =============================================================================

schema_exists() {
  [[ -f "$SCHEMA_FILE" ]]
}

# Parse schema and find file for an option
# Uses longest-match-wins for pattern matching
find_option_file() {
  local option="$1"
  local section="${2:-}"  # system, home, or hosts

  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    return 1
  fi

  local best_match=""
  local best_match_len=0
  local best_file=""

  # Determine which sections to search
  local sections
  if [[ -n "$section" ]]; then
    sections="$section"
  else
    sections="system home hosts"
  fi

  for sec in $sections; do
    # Extract patterns from section using sed
    # Format: "  pattern: file"
    while IFS=': ' read -r pattern file; do
      # Skip empty lines or comments
      [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
      # Remove trailing whitespace
      pattern="${pattern%%[[:space:]]}"
      file="${file%%[[:space:]]}"

      # Check if option matches pattern
      if option_matches_pattern "$option" "$pattern"; then
        local pattern_len=${#pattern}
        # Prefer longer (more specific) patterns
        if [[ $pattern_len -gt $best_match_len ]]; then
          best_match="$pattern"
          best_match_len=$pattern_len
          best_file="$file"
        fi
      fi
    done < <(sed -n "/^${sec}:$/,/^[a-z]*:$/p" "$SCHEMA_FILE" | grep -E '^\s+[a-zA-Z]' | sed 's/^[[:space:]]*//')
  done

  if [[ -n "$best_file" ]]; then
    echo "$best_file"
    return 0
  fi

  return 1
}

# Check if an option matches a pattern
# Patterns can use * for wildcards (e.g., "boot.*" matches "boot.loader.systemd-boot.enable")
option_matches_pattern() {
  local option="$1"
  local pattern="$2"

  # Convert pattern to regex:
  # - Escape dots
  # - Convert * to .*
  local regex="${pattern//./\\.}"
  regex="${regex//\*/.*}"

  # Full match for non-wildcard, prefix match for wildcard patterns
  if [[ "$pattern" == *"*" ]]; then
    [[ "$option" =~ ^${regex} ]]
  else
    [[ "$option" == "$pattern" ]]
  fi
}

# =============================================================================
# nixup schema - Show canonical file structure
# =============================================================================

schema_show() {
  local filter="${1:-}"

  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    echo "Create one with: nixup schema init"
    return 1
  fi

  if [[ -n "$filter" ]]; then
    # Show specific section or file
    echo -e "${BOLD}Options mapped to files matching '$filter':${NC}"
    echo ""

    grep -E "^\s+.*${filter}.*:" "$SCHEMA_FILE" | while IFS=': ' read -r pattern file; do
      pattern="${pattern##*( )}"
      file="${file%%[[:space:]]}"
      printf "  ${CYAN}%-40s${NC} → ${BLUE}%s${NC}\n" "$pattern" "$file"
    done
  else
    # Show full structure as tree
    echo -e "${BOLD}Canonical file structure:${NC}"
    echo ""

    for section in system home hosts packages; do
      echo -e "${YELLOW}$section:${NC}"
      sed -n "/^${section}:$/,/^[a-z]*:$/p" "$SCHEMA_FILE" | \
        grep -E '^\s+[a-zA-Z]' | \
        sed 's/^[[:space:]]*//' | \
        while IFS=': ' read -r pattern file; do
          pattern="${pattern%%[[:space:]]}"
          file="${file%%[[:space:]]}"
          printf "  ${CYAN}%-40s${NC} → ${BLUE}%s${NC}\n" "$pattern" "$file"
        done
      echo ""
    done
  fi
}

# =============================================================================
# nixup schema tree - Show as directory tree
# =============================================================================

schema_tree() {
  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    return 1
  fi

  echo -e "${BOLD}Files with mapped options:${NC}"
  echo ""

  # Extract unique files and their option counts
  grep -E '^\s+[a-zA-Z].*:' "$SCHEMA_FILE" | \
    sed 's/^[[:space:]]*//' | \
    awk -F': ' '{files[$2]++} END {for (f in files) print files[f], f}' | \
    sort -t'/' -k1,1 -k2,2 | \
    while read -r count file; do
      printf "  ${BLUE}%-50s${NC} ${CYAN}(%d options)${NC}\n" "$file" "$count"
    done
}

# =============================================================================
# nixup where - Find which file owns an option
# =============================================================================

schema_where() {
  local option="$1"

  if [[ -z "$option" ]]; then
    print_error "Usage: nixup where <option>"
    echo "Example: nixup where boot.loader.systemd-boot.enable"
    return 1
  fi

  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    return 1
  fi

  local file
  file=$(find_option_file "$option")

  if [[ -n "$file" ]]; then
    local full_path="${CONFIG_DIR}/${file}"
    if [[ -f "$full_path" ]]; then
      echo -e "${CYAN}$option${NC} → ${BLUE}$file${NC}"
      echo ""
      echo -e "${BOLD}Current value in config:${NC}"
      # Try to find the option in the file
      if grep -q "${option##*.}" "$full_path" 2>/dev/null; then
        grep -n "${option##*.}" "$full_path" | head -5 | sed 's/^/  /'
      else
        echo "  (not explicitly set in file)"
      fi
    else
      echo -e "${CYAN}$option${NC} → ${BLUE}$file${NC}"
      echo -e "${YELLOW}(file does not exist yet)${NC}"
    fi
  else
    print_error "No mapping found for option: $option"
    echo ""
    echo "This option may need to be added to schema.yaml"
    echo "Or check if you're using the correct option path"
    return 1
  fi
}

# =============================================================================
# nixup schema validate - Check schema against actual files
# =============================================================================

schema_validate() {
  if ! schema_exists; then
    print_error "Schema not found: $SCHEMA_FILE"
    return 1
  fi

  echo -e "${BOLD}Validating schema against filesystem...${NC}"
  echo ""

  local errors=0
  local warnings=0

  # Check that all files in schema exist
  grep -E '^\s+[a-zA-Z].*:' "$SCHEMA_FILE" | \
    sed 's/^[[:space:]]*//' | \
    awk -F': ' '{print $2}' | \
    sort -u | \
    while read -r file; do
      # Skip directory patterns (ending in /)
      [[ "$file" == */ ]] && continue
      # Skip patterns with placeholders
      [[ "$file" == *"{"*"}"* ]] && continue

      local full_path="${CONFIG_DIR}/${file}"
      if [[ ! -f "$full_path" ]]; then
        echo -e "  ${YELLOW}warning:${NC} File not found: $file"
        ((warnings++))
      fi
    done

  # Check for .nix files not in schema
  echo ""
  echo -e "${BOLD}Checking for unmapped files...${NC}"

  find "$CONFIG_DIR" -name "*.nix" -type f | while read -r file; do
    local rel_file="${file#$CONFIG_DIR/}"
    # Skip certain files
    [[ "$rel_file" == flake.nix ]] && continue
    [[ "$rel_file" == *hardware-configuration.nix ]] && continue
    [[ "$rel_file" == */default.nix ]] && continue
    [[ "$rel_file" == scripts/* ]] && continue

    if ! grep -q "$rel_file" "$SCHEMA_FILE" 2>/dev/null; then
      echo -e "  ${CYAN}info:${NC} Not in schema: $rel_file"
    fi
  done

  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    print_success "Schema validation passed"
  else
    echo ""
    echo "Errors: $errors, Warnings: $warnings"
  fi
}
