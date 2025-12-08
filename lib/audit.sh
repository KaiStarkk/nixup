#!/usr/bin/env bash
# audit.sh - System conformity and untracked state detection

# =============================================================================
# Audit severity levels and output
# =============================================================================

AUDIT_INFO_COUNT=0
AUDIT_WARN_COUNT=0

audit_info() {
  AUDIT_INFO_COUNT=$((AUDIT_INFO_COUNT + 1))
  echo "  ${BLUE}info:${NC} $1"
}

audit_warn() {
  AUDIT_WARN_COUNT=$((AUDIT_WARN_COUNT + 1))
  echo "  ${YELLOW}warn:${NC} $1"
}

audit_section() {
  echo ""
  echo "${BOLD}$1${NC}"
}

audit_ok() {
  echo "  ${GREEN}✓${NC} $1"
}

audit_summary() {
  echo ""
  echo "${BOLD}Summary:${NC}"
  if [[ $AUDIT_WARN_COUNT -eq 0 && $AUDIT_INFO_COUNT -eq 0 ]]; then
    echo "  ${GREEN}✓${NC} System is fully conformant"
  else
    [[ $AUDIT_WARN_COUNT -gt 0 ]] && echo "  ${YELLOW}$AUDIT_WARN_COUNT warning(s)${NC}"
    [[ $AUDIT_INFO_COUNT -gt 0 ]] && echo "  ${BLUE}$AUDIT_INFO_COUNT info${NC}"
  fi
}

# =============================================================================
# /boot audit - compare against current system
# =============================================================================

audit_boot() {
  audit_section "Auditing /boot"

  local issues=0
  local system_kernel system_initrd

  # Get expected paths from current system
  system_kernel=$(readlink -f /run/current-system/kernel 2>/dev/null)
  system_initrd=$(readlink -f /run/current-system/initrd 2>/dev/null)

  if [[ ! -d /boot ]]; then
    audit_warn "/boot directory not found"
    return
  fi

  # Check for unexpected files in /boot (not from nix store or standard bootloader files)
  local unexpected_files=()
  while IFS= read -r -d '' file; do
    # Skip standard bootloader directories and files
    case "$file" in
      /boot/EFI*|/boot/loader*|/boot/grub*|/boot/nixos*|/boot/kernels*) continue ;;
    esac
    # Check if file points to nix store or is a known bootloader file
    if [[ -L "$file" ]]; then
      local target
      target=$(readlink -f "$file")
      [[ "$target" == /nix/store/* ]] && continue
    fi
    # Flag non-nix-managed files
    if [[ -f "$file" && ! "$file" =~ \.(old|bak)$ ]]; then
      unexpected_files+=("$file")
    fi
  done < <(find /boot -maxdepth 3 -type f -print0 2>/dev/null)

  if [[ ${#unexpected_files[@]} -gt 0 ]]; then
    for f in "${unexpected_files[@]}"; do
      audit_info "Unexpected file: $f"
    done
  else
    audit_ok "/boot contains only managed files"
  fi
}

# =============================================================================
# /usr audit - NixOS should only have /usr/bin/env
# =============================================================================

audit_usr() {
  audit_section "Auditing /usr"

  if [[ ! -d /usr ]]; then
    audit_ok "/usr does not exist (correct for minimal NixOS)"
    return
  fi

  local non_compliant=()

  # Check everything in /usr
  while IFS= read -r -d '' item; do
    case "$item" in
      /usr/bin) continue ;;  # /usr/bin is expected
      /usr/bin/env) continue ;;  # /usr/bin/env is the only expected file
      *)
        non_compliant+=("$item")
        ;;
    esac
  done < <(find /usr -mindepth 1 -print0 2>/dev/null)

  if [[ ${#non_compliant[@]} -eq 0 ]]; then
    audit_ok "/usr contains only /usr/bin/env (NixOS compliant)"
  else
    for item in "${non_compliant[@]}"; do
      audit_warn "Non-standard /usr content: $item"
    done
  fi
}

# =============================================================================
# /etc audit - find unmanaged files (not symlinks to nix store or /etc/static)
# =============================================================================

audit_etc() {
  audit_section "Auditing /etc"

  # Files that are expected to be mutable on NixOS
  local -a allowed_mutable=(
    "/etc/machine-id"
    "/etc/NIXOS"
    "/etc/passwd"
    "/etc/passwd-"
    "/etc/group"
    "/etc/group-"
    "/etc/shadow"
    "/etc/shadow-"
    "/etc/gshadow"
    "/etc/gshadow-"
    "/etc/subuid"
    "/etc/subgid"
    "/etc/adjtime"
    "/etc/mtab"
    "/etc/fstab"
    "/etc/crypttab"
    "/etc/hostname"
    "/etc/hosts"
    "/etc/resolv.conf"
    "/etc/localtime"
    "/etc/.pwd.lock"
    "/etc/.updated"
  )

  # Directories with expected mutable content
  local -a allowed_dirs=(
    "/etc/nixos"
    "/etc/NetworkManager"
    "/etc/ssh"
    "/etc/pki"
    "/etc/ssl/certs"
  )

  local unmanaged=()

  while IFS= read -r -d '' file; do
    [[ ! -f "$file" ]] && continue

    # Skip allowed mutable files
    local skip=false
    for allowed in "${allowed_mutable[@]}"; do
      [[ "$file" == "$allowed" ]] && { skip=true; break; }
    done
    $skip && continue

    # Skip files in allowed directories
    for dir in "${allowed_dirs[@]}"; do
      [[ "$file" == "$dir"/* ]] && { skip=true; break; }
    done
    $skip && continue

    # Check if it's a symlink to nix store or /etc/static
    if [[ -L "$file" ]]; then
      local target
      target=$(readlink "$file")
      [[ "$target" == /nix/store/* || "$target" == /etc/static/* || "$target" == ../nix/store/* ]] && continue
    else
      # Not a symlink - this is unmanaged
      unmanaged+=("$file")
    fi
  done < <(find /etc -maxdepth 2 -type f -print0 2>/dev/null; find /etc -maxdepth 2 -type l -print0 2>/dev/null)

  if [[ ${#unmanaged[@]} -eq 0 ]]; then
    audit_ok "/etc files are managed by NixOS"
  else
    local count=0
    for f in "${unmanaged[@]}"; do
      count=$((count + 1))
      if [[ $count -le 10 ]]; then
        audit_warn "Unmanaged: $f"
      fi
    done
    if [[ $count -gt 10 ]]; then
      audit_warn "... and $((count - 10)) more unmanaged files"
    fi
  fi
}

# =============================================================================
# Home dotfiles audit - check ~/.*
# =============================================================================

audit_home_dotfiles() {
  audit_section "Auditing home dotfiles"

  local home_dir="${HOME:-/home/$USER}"

  # Get list of dotfiles declared in nixup hooks (from config dir)
  local -a declared_dotfiles=()
  if [[ -d "$CONFIG_DIR" ]]; then
    # Look for dotfiles hooks in the config
    while IFS= read -r line; do
      # Extract filenames from home.file declarations or xdg.configFile
      local name
      name=$(echo "$line" | grep -oP '"\.[^"]+"|home\.file\.\s*"\.[^"]+"' | tr -d '"' | head -1)
      [[ -n "$name" ]] && declared_dotfiles+=("$name")
    done < <(grep -rh '^\s*"\.' "$CONFIG_DIR" 2>/dev/null || true)
  fi

  # Standard dotfiles/directories that are expected (runtime state, app data)
  local -a allowed_dotfiles=(
    # Nix
    ".cache"
    ".config"
    ".local"
    ".nix-defexpr"
    ".nix-profile"
    ".nix-channels"
    # Common app state directories
    ".cargo"
    ".rustup"
    ".npm"
    ".gnupg"
    ".ssh"
    ".pki"
    ".mozilla"
    ".librewolf"
    ".thunderbird"
    ".steam"
    ".icons"
    ".themes"
    ".fonts"
    # Development toolchains
    ".dotnet"
    ".nuget"
    ".java"
    ".android"
    ".gradle"
    # Editor state
    ".vscode"
    ".cursor"
    ".emacs.d"
    # Cloud/credentials
    ".aws"
    ".azure"
    ".kube"
    # Misc runtime
    ".pulse-cookie"
    ".Xauthority"
    ".yubico"
    # Claude/AI tools
    ".claude"
    ".gemini"
    # Nixup's own backup dir
    ".config-backups"
  )

  local unmanaged=()
  local non_xdg=()

  for dotfile in "$home_dir"/.*; do
    [[ ! -e "$dotfile" ]] && continue
    local name
    name=$(basename "$dotfile")

    # Skip . and ..
    [[ "$name" == "." || "$name" == ".." ]] && continue

    # Skip allowed standard dotfiles
    local skip=false
    for allowed in "${allowed_dotfiles[@]}"; do
      [[ "$name" == "$allowed" ]] && { skip=true; break; }
    done
    $skip && continue

    # Check if symlink to nix store (managed by home-manager)
    if [[ -L "$dotfile" ]]; then
      local target
      target=$(readlink "$dotfile")
      [[ "$target" == /nix/store/* ]] && continue
    fi

    # Check if declared in nixup hooks
    for declared in "${declared_dotfiles[@]}"; do
      [[ "$name" == "$declared" ]] && { skip=true; break; }
    done
    $skip && continue

    # Categorize: is this a config file that should be in XDG?
    case "$name" in
      # Known config dotfiles that should use XDG
      .bashrc|.bash_profile|.bash_logout|.zshrc|.zprofile|.profile)
        # Shell configs are acceptable at home level
        continue
        ;;
      .gitconfig|.vimrc|.tmux.conf|.npmrc|.yarnrc)
        non_xdg+=("$name → should be in ~/.config/")
        ;;
      .bash_history|.zsh_history|.python_history|.node_repl_history)
        # History files - info level
        audit_info "$name (history file - ephemeral)"
        ;;
      .lesshst|.wget-hsts)
        # Minor state files
        continue
        ;;
      *)
        # Unknown dotfile - flag it
        if [[ -d "$dotfile" ]]; then
          unmanaged+=("$name/ (directory)")
        else
          unmanaged+=("$name")
        fi
        ;;
    esac
  done

  # Report non-XDG compliant configs
  for item in "${non_xdg[@]}"; do
    audit_info "Non-XDG: $item"
  done

  # Report unmanaged dotfiles
  if [[ ${#unmanaged[@]} -eq 0 && ${#non_xdg[@]} -eq 0 ]]; then
    audit_ok "Home dotfiles are managed or XDG-compliant"
  else
    for item in "${unmanaged[@]}"; do
      audit_warn "Unmanaged: ~/$item"
    done
  fi
}

# =============================================================================
# Main audit entry point
# =============================================================================

audit_run() {
  local do_boot=false
  local do_usr=false
  local do_etc=false
  local do_home=false
  local do_all=true

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --boot) do_boot=true; do_all=false; shift ;;
      --usr) do_usr=true; do_all=false; shift ;;
      --etc) do_etc=true; do_all=false; shift ;;
      --home) do_home=true; do_all=false; shift ;;
      --help|-h)
        echo "Usage: nixup audit [--boot] [--usr] [--etc] [--home]"
        echo ""
        echo "Check system conformity and detect untracked state."
        echo ""
        echo "Options:"
        echo "  --boot  Audit /boot directory"
        echo "  --usr   Audit /usr structure (should only have /usr/bin/env)"
        echo "  --etc   Audit /etc for unmanaged files"
        echo "  --home  Audit home directory dotfiles"
        echo ""
        echo "With no options, runs all audits."
        return 0
        ;;
      *) print_error "Unknown option: $1"; return 1 ;;
    esac
  done

  echo "${BOLD}NixOS System Audit${NC}"

  if $do_all || $do_boot; then
    audit_boot
  fi

  if $do_all || $do_usr; then
    audit_usr
  fi

  if $do_all || $do_etc; then
    audit_etc
  fi

  if $do_all || $do_home; then
    audit_home_dotfiles
  fi

  audit_summary
}
