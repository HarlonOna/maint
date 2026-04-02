#!/usr/bin/env bash
###############################################################################
# Script Name:   # maint (Fedora Maintenance Pro)
# Description:   # Comprehensive maintenance and diagnostic tool for Fedora Linux.
#                # Includes backups, kernel optimization, hardware checks, and more.
# Author:        # HarlonOna
# Version:       # 10.14.1
# License:       # GPL-3.0
# GitHub:        # https://github.com/HarlonOna/maint/
###############################################################################

set -uo pipefail
IFS=$'\n\t'

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'
ESC=$(printf '\033')


cleanup() {
    echo -e "${NC}\n"
    warn "Script aborted by User."
    exit 1
}

trap cleanup SIGINT SIGTERM

# --- Uniform separator lines ---
SEP_LINE="${MAGENTA}========================================================${NC}"
sep() { echo -e "$SEP_LINE"; }

# --- CHECK DEPENDENCIES ---
check_deps() {
    local missing=()
    command -v smartctl >/dev/null 2>&1 || missing+=("smartmontools")
    command -v curl >/dev/null 2>&1     || missing+=("curl")
    command -v flatpak >/dev/null 2>&1  || missing+=("flatpak")
    command -v hd-idle >/dev/null 2>&1  || missing+=("hd-idle")
    command -v fwupdmgr >/dev/null 2>&1 || missing+=("fwupd")

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${YELLOW} [WARN] The following programs are missing:${NC}"
        for item in "${missing[@]}"; do echo -e "  - $item"; done
        read -rp "Do you want to install them now? (y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            # Special case hd-idle: might not be in standard repos
            if [[ " ${missing[@]} " =~ " hd-idle " ]]; then
                # Check if hd-idle is available in active repos
                if ! dnf list available hd-idle &>/dev/null; then
                    echo -e "${YELLOW}hd-idle is not in the standard repos. Attempting to enable RPM Fusion...${NC}"
                    # Enable RPM Fusion free if not present
                    if ! dnf repolist | grep -q "rpmfusion-free"; then
                        sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
                    fi
                fi
            fi
            sudo dnf install -y "${missing[@]}"
        else
            echo -e "${RED}Some functions will not work correctly.${NC}"
            sleep 2
        fi
    fi
}

# Log preparation
SYS_LOG_DIR="/var/log/sys-maintenance"
[[ ! -d "$SYS_LOG_DIR" ]] && sudo mkdir -p "$SYS_LOG_DIR" 2>/dev/null
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$SYS_LOG_DIR/maintenance-$TIMESTAMP.log"

# Desktop notification
send_notify() {
    if command -v notify-send >/dev/null 2>&1; then
        local user_id=$(logname 2>/dev/null || echo "$USER")
        sudo -u "$user_id" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$user_id")/bus notify-send -i "system-run" "Maintenance Pro" "$1" 2>/dev/null
    fi
}

log() { sudo sh -c "echo '[$(date '+%Y-%m-%d %H:%M:%S')] $1' >> '$LOG_FILE'" 2>/dev/null; }
info()    { printf "${CYAN}[INFO]${NC} %s\n" "$1";    log "[INFO] $1"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$1";    log "[OK] $1"; }
warn()    { printf "${YELLOW} [WARN]${NC} %s\n" "$1";    log "[WARN] $1"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$1";   log "[ERROR] $1"; }
pause() { echo -en "${CYAN} Press [Enter] to continue...${NC}"; read -r; }
show_with_pager() { if command -v less >/dev/null 2>&1; then LESS=FRX less -R; else cat; fi; }

# --- Terminal start function (with automatic fallback on missing monitor) ---
# Call: start_in_terminal "command" [same_window]
# same_window = "true" => Execution in current terminal (blocking)
# otherwise: automatic decision (new window if possible, else current)
start_in_terminal() {
    local cmd="$1"
    local force_same="${2:-false}"

    # If requested or no GUI available, run directly in current terminal
    if [[ "$force_same" == "true" ]] || [[ -z "${DISPLAY:-}" ]]; then
        if [[ -z "${DISPLAY:-}" ]]; then
            echo -e "${YELLOW}No graphical environment detected – running command in current terminal.${NC}"
        fi
        eval "$cmd"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return 0
    fi

    # GUI exists – try to find a terminal emulator
    if command -v konsole >/dev/null 2>&1; then
        konsole -e bash -c "$cmd" &
    elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -c "$cmd" &
    elif command -v xterm >/dev/null 2>&1; then
        xterm -e bash -c "$cmd" &
    else
        echo -e "${YELLOW}No terminal emulator found – running command in current terminal.${NC}"
        eval "$cmd"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
    fi
    sleep 1

}

# --- Uniform prompt: New terminal or current? ---
# Call: ask_and_start "command" "description" [default_new]
# description: displayed in the menu text (e.g., "s-tui")
# default_new: if "true", option 2 (new terminal) is suggested as default
ask_and_start() {
    local cmd="$1"
    local desc="$2"
    local default_new="${3:-false}"

    echo -e "${YELLOW}Start $desc in the current terminal or a new window?${NC}"
    echo -e " 1) Current terminal (blocks the script until closed)"
    echo -e " 2) New terminal window (runs in background)"

    local prompt="Choice (1/2): "
    if [[ "$default_new" == "true" ]]; then
        prompt="Choice (1/2) [2]: "
    fi
    read -rp "$prompt" term_choice

    if [[ "$term_choice" == "1" ]]; then
        start_in_terminal "$cmd" "true"
    elif [[ "$term_choice" == "2" ]] || [[ -z "$term_choice" && "$default_new" == "true" ]]; then
        start_in_terminal "$cmd"
    else
        warn "Invalid choice. Starting in current terminal."
        start_in_terminal "$cmd" "true"
    fi
}

# --- UNINSTALLER ---
confirm_and_remove() {
    local category_name="$1"; local packages="$2"
    clear
    sep
    echo -e "${WHITE}${BOLD}   Category: $category_name ${NC}"
    sep
    echo -e "${YELLOW}Suggested for uninstallation:${NC}\n$packages" | tr ' ' '\n' | sed 's/^/  - /'
    sep
    read -rp "Remove? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && { info "Uninstalling..."; sudo dnf remove -y $packages; success "Done."; } || warn "Aborted."
    pause
}

# --- HD-IDLE CONTROL (persistent daemon with -n) ---
manage_hd_idle() {
    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   HDD Spindown (hd-idle) Control ${NC}"
        sep
        echo -e "${YELLOW} Powers down mechanical hard drives during inactivity,${NC}"
        echo -e "${YELLOW} to save power and extend lifespan.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Select HDD & set spindown timer"
        echo -e "${CYAN} 2)${NC} Current status & config     (is hd-idle running?)"
        echo -e "${CYAN} 3)${NC} Disable hd-idle completely  (Stops the service)"
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -p "> " hchoice
        case "$hchoice" in
            1)
                info "Searching for HDDs..."
                mapfile -t HDDS < <(lsblk -dn -o NAME,ROTA | grep " 1$" | awk '{print "/dev/"$1}')
                if [ ${#HDDS[@]} -eq 0 ]; then
                    error "No mechanical HDDs found!"
                    pause; continue
                fi
                for i in "${!HDDS[@]}"; do echo -e "${CYAN}$((i+1)))${NC} ${HDDS[i]}"; done
                read -rp "Choice: " hsel
                if [[ "$hsel" -gt 0 && "$hsel" -le "${#HDDS[@]}" ]]; then
                    DEV_PATH="${HDDS[hsel-1]}"
                    DEV_NAME=$(basename "$DEV_PATH")
                    read -rp "Inactivity until spindown (in minutes, default 10): " mins
                    mins=${mins:-10}
                    secs=$((mins * 60))

                    # Override file with -n (foreground) and explicit service type
                    sudo mkdir -p /etc/systemd/system/hd-idle.service.d
                    cat <<EOF | sudo tee /etc/systemd/system/hd-idle.service.d/override.conf >/dev/null
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/hd-idle -n -a $DEV_NAME -i $secs
Restart=on-failure
EOF
                    sudo systemctl daemon-reload
                    sudo systemctl restart hd-idle
                    sudo systemctl enable hd-idle

                    # Check if service is active
                    sleep 2
                    if systemctl is-active --quiet hd-idle; then
                        success "Timer set to $mins min for $DEV_NAME. Service running."
                    else
                        error "Service could not be started. Check logs with: journalctl -u hd-idle"
                    fi
                fi; pause ;;
            2)
                echo -e "${YELLOW}Configuration:${NC}"
                [ -f /etc/systemd/system/hd-idle.service.d/override.conf ] && cat /etc/systemd/system/hd-idle.service.d/override.conf || echo "No config."
                echo -e "\n${YELLOW}Status:${NC}"
                if systemctl is-active --quiet hd-idle; then
                    echo -e "${GREEN}active${NC}"
                    # Try to get the state of the configured drive
                    local cfg_dev=$(grep -oP '(?<=-a )[^ ]+' /etc/systemd/system/hd-idle.service.d/override.conf 2>/dev/null)
                    if [[ -n "$cfg_dev" ]]; then
                        local state=$(sudo hdparm -C "/dev/$cfg_dev" 2>/dev/null | grep -o 'drive state is: [a-z]*')
                        echo -e "\n${YELLOW}State of /dev/$cfg_dev:${NC} ${state:-unknown}"
                    fi
                else
                    echo -e "${RED}inactive${NC}"
                fi
                echo -e "\n${YELLOW}Log excerpt (last 5 lines):${NC}"
                sudo journalctl -u hd-idle -n 5 --no-pager
                pause ;;
            3)
                sudo systemctl disable --now hd-idle
                sudo rm -rf /etc/systemd/system/hd-idle.service.d
                sudo systemctl daemon-reload
                success "hd-idle disabled and configuration removed."; pause ;;
            0) break ;;
        esac
    done
}

# --- BACKUP (extended) ---
config_backup() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups"
    local current_bak="$base_dir/backup_$TIMESTAMP"
    mkdir -p "$current_bak"

    # 1. Standard Configs
    local files=("/etc/fstab" "/etc/dnf/dnf.conf" "/etc/hosts" "/etc/hostname" "/etc/default/grub" "$user_home/.bashrc" "/usr/local/bin/maint")
    for f in "${files[@]}"; do [[ -f "$f" ]] && cp "$f" "$current_bak/" 2>/dev/null; done

    # 2. Package lists
    rpm -qa --queryformat "%{NAME}\n" > "$current_bak/installed-packages.txt"
    flatpak list --app --columns=application > "$current_bak/flatpak-apps.txt" 2>/dev/null

    # 3. Firewall rules
    sudo firewall-cmd --list-all > "$current_bak/firewall-rules.txt" 2>/dev/null
    mkdir -p "$current_bak/firewalld-zones"
    sudo cp /etc/firewalld/zones/* "$current_bak/firewalld-zones/" 2>/dev/null

    # 4. Network connections (WLAN passwords, VPNs)
    mkdir -p "$current_bak/network-connections"
    sudo cp -r /etc/NetworkManager/system-connections/* "$current_bak/network-connections/" 2>/dev/null

    # 5. SSH configuration
    cp /etc/ssh/sshd_config "$current_bak/" 2>/dev/null
    [[ -f "$user_home/.ssh/config" ]] && cp "$user_home/.ssh/config" "$current_bak/" 2>/dev/null

    # 6. SELinux configuration
    cp /etc/selinux/config "$current_bak/" 2>/dev/null

    # 7. CRON jobs
    crontab -l > "$current_bak/crontab-user.txt" 2>/dev/null
    sudo crontab -l > "$current_bak/crontab-root.txt" 2>/dev/null

    # 8. KDE Plasma Settings (Desktop-specific)
    mkdir -p "$current_bak/plasma-configs"
    cp "$user_home/.config/kdeglobals" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/plasmashellrc" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/kwinrc" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/kactivitymanagerdrc" "$current_bak/plasma-configs/" 2>/dev/null

    # Clean up old backups (max 5)
    local count=$(ls -1d "$base_dir"/backup_* 2>/dev/null | wc -l)
    [[ $count -gt 5 ]] && ls -1dt "$base_dir"/backup_* | tail -n +6 | xargs rm -rf

    success "Backup created in $current_bak"
}

# --- SMART ---
wait_for_smart() {
    local dev=$1; local type=$2
    ( while true; do sleep 45; if ! sudo smartctl -a "$dev" | grep -q "Self-test routine in progress"; then send_notify "SMART $type Test finished!"; break; fi; done ) & disown
}

smart_disk_check() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   SMART Hardware Check ${NC}"
    sep
    echo -e "${YELLOW} Check the health status of drives.${NC}"
    sep
    info "Searching hardware..."
    mapfile -t RAW_DISKS < <(sudo smartctl --scan-open | awk '{print $1}')
    [[ ${#RAW_DISKS[@]} -eq 0 ]] && mapfile -t RAW_DISKS < <(lsblk -dn -o NAME | awk '{print "/dev/"$1}')
    local DISK_LABELS=()
    for dev in "${RAW_DISKS[@]}"; do
        local model=$(sudo smartctl -i "$dev" | grep -E "Device Model|Model Number|User Capacity" | head -n 1 | cut -d: -f2 | sed 's/^[ \t]*//')
        DISK_LABELS+=("$dev | ${model:-Unknown}")
    done
    for i in "${!DISK_LABELS[@]}"; do printf "${CYAN} %d)${NC} %s\n" "$((i+1))" "${DISK_LABELS[i]}"; done
    sep
    read -rp "Choice (0 for Back): " sel
    if [[ "$sel" -gt 0 && "$sel" -le "${#DISK_LABELS[@]}" ]]; then
        DEV=$(echo "${DISK_LABELS[sel-1]}" | cut -d'|' -f1 | xargs)
        MODEL=$(echo "${DISK_LABELS[sel-1]}" | cut -d'|' -f2 | xargs)
        while true; do
            clear
            sep
            echo -e "${WHITE}${BOLD}   SMART Menu: $DEV ${NC}"
            echo -e "${YELLOW}   Model: $MODEL ${NC}"
            sep
            echo -e "${YELLOW}Runs diagnostic tests and reads sensor data.${NC}"
            sep
            echo -e "${CYAN} 1)${NC} Health Status (Quick Check)"
            echo -e "${CYAN} 2)${NC} All SMART Attributes (Details)"
            echo -e "${CYAN} 3)${NC} Short Self-Test (approx. 2 min)"
            echo -e "${CYAN} 4)${NC} Long Self-Test (Comprehensive)"
            echo -e "${CYAN} 5)${NC} Show test results"
            sep
            echo -e "${CYAN} 0)${NC} Back to selection"
            sep
            read -p "> " schoice
            case "$schoice" in
                1) sudo smartctl -H "$DEV" | sed -e "s/PASSED/${ESC}[1;32mPASSED${ESC}[0m/g" -e "s/FAILED/${ESC}[1;31mFAILED${ESC}[0m/g"; pause ;;
                2) sudo smartctl -A "$DEV" | show_with_pager; pause ;;
                3) sudo smartctl -t short "$DEV"; wait_for_smart "$DEV" "Short"; pause ;;
                              4)
                    echo -e "${YELLOW}A long self-test can take several hours${NC}"
                    echo -e "${YELLOW}and put a heavy load on the disk. The test runs in the background.${NC}"
                    read -rp "Start Long Self-Test? (y/N): " long_confirm
                    if [[ "$long_confirm" =~ ^[Yy]$ ]]; then
                        sudo smartctl -t long "$DEV"
                        wait_for_smart "$DEV" "Long"
                    else
                        warn "Aborted."
                    fi
                    pause ;;
                5) sudo smartctl -l selftest "$DEV" | show_with_pager; pause ;;
                0) break ;;
            esac
        done
    fi
}

# --- SET DEFAULT KERNEL ---
set_default_kernel() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   Set default kernel ${NC}"
    sep
    echo -e "${YELLOW}Selects the kernel to be booted by default.${NC}"
    echo -e "${YELLOW}This is preserved even after kernel updates (as long as it's installed).${NC}"
    sep

    # List all vmlinuz-* files in /boot (excluding rescue)
    mapfile -t kernels < <(find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*-rescue-*' | sort -V)

    if [ ${#kernels[@]} -eq 0 ]; then
        error "No kernel files found in /boot."
        pause
        return
    fi

    # Display with numbers
    local idx=1
    for kernel in "${kernels[@]}"; do
        version=$(basename "$kernel" | sed 's/^vmlinuz-//')
        echo -e "${CYAN} $idx)${NC} $version"
        ((idx++))
    done
    sep
    echo -e "${YELLOW}Choose the kernel to be set as default.${NC}"
    read -rp "Number (Enter = Cancel): " choice

    if [[ -z "$choice" ]]; then
        warn "Cancel."
        pause
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#kernels[@]} ]; then
        selected="${kernels[$((choice-1))]}"
        version=$(basename "$selected" | sed 's/^vmlinuz-//')

        echo -e "${YELLOW}Setting $version as default kernel...${NC}"
        if sudo grubby --set-default "$selected"; then
            success "Default kernel set to $version."
            echo -e "${YELLOW}The change will take effect on the next reboot.${NC}"
        else
            error "Error setting default. Check if 'grubby' is installed."
        fi
    else
        error "Invalid choice."
    fi
    pause
}

# --- KERNEL MENU ---
kernel_menu() {
    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Kernel Management ${NC}"
        sep
        echo -e "${YELLOW} Install or manage kernels.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Install CachyOS Kernel"
        echo -e "${CYAN} 2)${NC} Remove unneeded kernels"
        echo -e "${CYAN} 3)${NC} Set default kernel (permanent for GRUB)"
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -p "> " kchoice
        case "$kchoice" in
            1) install_cachyos_kernel ;;
            2) remove_old_kernels ;;
            3) set_default_kernel ;;
            0) break ;;
            *) error "Invalid choice."; pause ;;
        esac
    done
}

# --- REMOVE OLD KERNELS ---
remove_old_kernels() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   Remove unneeded kernels ${NC}"
    sep
    echo -e "${YELLOW} Warning: Only remove kernels you truly no longer need.${NC}"
    echo -e "${YELLOW} Keep at least one older kernel as a fallback in case${NC}"
    echo -e "${YELLOW} the current one fails to boot.${NC}"
    echo -e "${YELLOW} Without a fallback, the system can become unusable!${NC}"
    sep

    # Get current kernel (without architecture, e.g., 6.19.9-200.fc43)
    local current_kernel_full=$(uname -r)
    local current_kernel="${current_kernel_full%.*}"  # Removes .x86_64 or similar
    echo -e "${GREEN}Currently running kernel: ${WHITE}${BOLD}$current_kernel_full${NC}"
    sep

    # Gather all installed kernel versions (without architecture)
    local kernel_versions=()
    while read -r pkg; do
        # Extract version from packages like kernel-core-6.19.8-200.fc43.x86_64
        if [[ "$pkg" =~ ^(kernel-core|kernel|kernel-cachyos-core)-([0-9].+)\.(x86_64|noarch) ]]; then
            version="${BASH_REMATCH[2]}"
            # Avoid duplicates
            if [[ ! " ${kernel_versions[@]} " =~ " ${version} " ]]; then
                kernel_versions+=("$version")
            fi
        fi
    done < <(rpm -qa | grep -E "^(kernel-core|kernel|kernel-cachyos-core)-[0-9]")

    if [ ${#kernel_versions[@]} -eq 0 ]; then
        echo -e "${YELLOW}No additional kernels found.${NC}"
        pause
        return
    fi

    # List of selectable kernels (all except current)
    local selectable=()
    local selectable_versions=()
    local idx=1
    echo -e "${CYAN}Available kernels (except current):${NC}"
    for ver in "${kernel_versions[@]}"; do
        # Compare without architecture
        if [[ "$ver" != "$current_kernel" ]]; then
            echo -e " ${CYAN}$idx)${NC} $ver"
            selectable+=("$ver")
            selectable_versions+=("$ver")
            ((idx++))
        fi
    done

    if [ ${#selectable[@]} -eq 0 ]; then
        echo -e "${GREEN}No old kernels found. All clean.${NC}"
        pause
        return
    fi

    sep
    echo -e "${YELLOW}Choose the number(s) of the kernel(s) to remove.${NC}"
    echo -e "${YELLOW}Separate multiple choices with spaces. Enter = Cancel.${NC}"
    read -rp "> " choices

    if [[ -z "$choices" ]]; then
        warn "Cancel."
        pause
        return
    fi

    # Parse selection and gather packages
    local to_remove_pkgs=()
    for choice in $choices; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#selectable[@]} ]; then
            local ver="${selectable[$choice-1]}"
            # Find all packages belonging to this version
            mapfile -t pkgs < <(rpm -qa | grep -E "(^kernel-core-${ver}|^kernel-${ver}|^kernel-modules-${ver}|^kernel-devel-${ver}|^kernel-cachyos-core-${ver}|^kernel-cachyos-${ver}|^kernel-cachyos-modules-${ver}|^kernel-cachyos-devel-${ver})" | sort -u)
            for p in "${pkgs[@]}"; do
                to_remove_pkgs+=("$p")
            done
        else
            warn "Invalid choice: $choice"
        fi
    done

    if [ ${#to_remove_pkgs[@]} -eq 0 ]; then
        warn "No valid kernels selected."
        pause
        return
    fi

    # Show final warning
    echo -e "${RED}${BOLD}WARNING:${NC} You are removing the following kernel packages:"
    for p in "${to_remove_pkgs[@]}"; do
        echo "  - $p"
    done
    echo -e "${YELLOW}Make sure at least one working kernel (besides the current one) remains,${NC}"
    echo -e "${YELLOW}in case the current kernel causes problems.${NC}"
    read -rp "Really remove? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo dnf remove -y "${to_remove_pkgs[@]}"
        success "Kernel removed."
        echo -e "${YELLOW}Note: GRUB configuration was automatically updated.${NC}"
    else
        warn "Aborted."
    fi
    pause
}

        # --- SYSTEMD SERVICE MANAGER ---
        service_manager() {
        while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Systemd Service Manager ${NC}"
        sep
        echo -e "${YELLOW} Manage Systemd services (View, Start, Stop, etc.)${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Show all services"
        echo -e "${CYAN} 2)${NC} Show running services"
        echo -e "${CYAN} 3)${NC} Show failed services"
        echo -e "${CYAN} 4)${NC} Show enabled autostart services"
        echo -e "${CYAN} 5)${NC} Select service for actions"
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -p "> " svc_choice
        case "$svc_choice" in
            1)
                SYSTEMD_COLORS=1 systemctl list-units --type=service | show_with_pager
                pause
                ;;
            2)
                SYSTEMD_COLORS=1 systemctl list-units --type=service --state=running | show_with_pager
                pause
                ;;
            3)
                SYSTEMD_COLORS=1 systemctl list-units --type=service --state=failed | show_with_pager
                pause
                ;;
            4)
                SYSTEMD_COLORS=1 systemctl list-unit-files --type=service --state=enabled | show_with_pager
                pause
                ;;
            5)
                echo -e "${YELLOW}Enter the exact service name (e.g., sshd, NetworkManager, httpd):${NC}"
                read -rp "> " service_name
                if [[ -z "$service_name" ]]; then
                    warn "No name entered."
                    pause
                    continue
                fi
                # Automatically append .service if missing
                if [[ "$service_name" != *".service" ]]; then
                    service_name="${service_name}.service"
                fi
                # Check if service exists (with systemctl cat)
                if ! systemctl cat "$service_name" &>/dev/null; then
                    error "Service $service_name not found."
                    pause
                    continue
                fi
                # Submenu for actions
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Service: $service_name ${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Show status"
                    echo -e "${CYAN} 2)${NC} Show logs (last 20 lines)"
                    echo -e "${CYAN} 3)${NC} Start"
                    echo -e "${CYAN} 4)${NC} Stop"
                    echo -e "${CYAN} 5)${NC} Restart"
                    echo -e "${CYAN} 6)${NC} Enable (Autostart on boot)"
                    echo -e "${CYAN} 7)${NC} Disable (Remove autostart)"
                    sep
                    echo -e "${CYAN} 0)${NC} Back to service selection"
                    sep
                    read -p "> " action
                                    case "$action" in
                        1)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Status of $service_name ${NC}"
                            sep
                            SYSTEMD_COLORS=1 systemctl status "$service_name" --no-pager
                            sep
                            pause
                            ;;
                        2)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Logs of $service_name (last 20 lines) ${NC}"
                            sep
                            sudo journalctl -u "$service_name" -n 20 --no-pager
                            sep
                            pause
                            ;;
                        3)
                            echo -e "${YELLOW}Starting $service_name ...${NC}"
                            sudo systemctl start "$service_name"
                            if [ $? -eq 0 ]; then
                                success "$service_name started."
                            else
                                error "Start failed."
                            fi
                            pause
                            ;;
                        4)
                            read -rp "Really stop service $service_name? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl stop "$service_name"
                                success "$service_name stopped."
                            else
                                warn "Aborted."
                            fi
                            pause
                            ;;
                        5)
                            read -rp "Really restart service $service_name? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl restart "$service_name"
                                success "$service_name restarted."
                            else
                                warn "Aborted."
                            fi
                            pause
                            ;;
                        6)
                            sudo systemctl enable "$service_name"
                            success "$service_name enabled (Autostart)."
                            pause
                            ;;
                        7)
                            read -rp "Really disable autostart for $service_name? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl disable "$service_name"
                                success "$service_name disabled."
                            else
                                warn "Aborted."
                            fi
                            pause
                            ;;
                        0)
                            break
                            ;;
                        *)
                            error "Invalid choice."
                            pause
                            ;;
                    esac
                done
                ;;
            0) break ;;
            *) error "Invalid choice."; pause ;;
        esac
        done
        }

        # --- FLATPAK MANAGEMENT ---
flatpak_management() {
    # Check if flatpak is installed
    if ! command -v flatpak >/dev/null 2>&1; then
        error "Flatpak is not installed."
        pause
        return
    fi

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Flatpak Management ${NC}"
        sep
        echo -e "${YELLOW} Manage Flatpak applications (Update, Repair, Remove).${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Flatpaks Update & Repair"
        echo -e "${CYAN} 2)${NC} Show installed Flatpaks (List)"
        echo -e "${CYAN} 3)${NC} Show details of a Flatpak application"
        echo -e "${CYAN} 4)${NC} Reinstall Flatpak"
        echo -e "${CYAN} 5)${NC} Remove Flatpak"
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -p "> " fp_choice
        case "$fp_choice" in
            1)  info "Flatpak maintenance..."
                sudo flatpak update -y && sudo flatpak repair && sudo flatpak uninstall --unused -y; success "Done."; pause ;;
            2)
                clear
                sep
                echo -e "${WHITE}${BOLD}   Installed Flatpaks ${NC}"
                sep
                flatpak list --app --columns=application | show_with_pager
                pause
                ;;
            3)
                echo -e "${YELLOW}Enter the exact application name (e.g., org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "No name entered."
                    pause
                    continue
                fi
                # Check if installed
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name not found or not installed."
                    pause
                    continue
                fi
                clear
                sep
                echo -e "${WHITE}${BOLD}   Details for $app_name ${NC}"
                sep
                flatpak info "$app_name" | show_with_pager
                pause
                ;;
            4)
                echo -e "${YELLOW}Enter the exact application name (e.g., org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "No name entered."
                    pause
                    continue
                fi
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name not found or not installed."
                    pause
                    continue
                fi
                echo -e "${YELLOW}Reinstall Flatpak $app_name? (y/N):${NC}"
                read -rp "> " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    sudo flatpak uninstall -y "$app_name" && sudo flatpak install -y "$app_name"
                    if [ $? -eq 0 ]; then
                        success "$app_name reinstalled."
                    else
                        error "Reinstallation failed."
                    fi
                else
                    warn "Aborted."
                fi
                pause
                ;;
            5)
                echo -e "${YELLOW}Enter the exact application name (e.g., org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "No name entered."
                    pause
                    continue
                fi
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name not found or not installed."
                    pause
                    continue
                fi
                echo -e "${RED}${BOLD}WARNING: Removing $app_name${NC}"
                echo -e "${YELLOW}This deletes the application and all associated data.${NC}"
                read -rp "Really remove? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    sudo flatpak uninstall -y "$app_name"
                    if [ $? -eq 0 ]; then
                        success "$app_name removed."
                    else
                        error "Removal failed."
                    fi
                else
                    warn "Aborted."
                fi
                pause
                ;;
            0) break ;;
            *) error "Invalid choice."; pause ;;
        esac
    done
}

    # --- CACHYOS KERNEL INSTALLATION ---
    install_cachyos_kernel() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   CachyOS Kernel Installation ${NC}"
    sep
    echo -e "${YELLOW}This kernel is optimized for modern CPUs with x86_64_v3.${NC}"
    sep

    # Confirmation before installation
    echo -e "${YELLOW}Installing an alternative kernel can make the system unstable.${NC}"
    echo -e "${YELLOW}Ensure a recent backup is available.${NC}"
    read -rp "Continue? (y/N): " kernel_confirm
    if [[ ! "$kernel_confirm" =~ ^[Yy]$ ]]; then
        warn "Aborted."
        pause
        return
    fi

    # 1. Check CPU support (robust)
    info "Checking CPU support for x86_64_v3..."
    local supported=false

    # Method 1: gcc -march (if available)
    if command -v gcc >/dev/null 2>&1; then
        if gcc -march=x86-64-v3 -dM -E - < /dev/null > /dev/null 2>&1; then
            supported=true
        fi
    fi

    # Method 2: If gcc is not available, evaluate CPU flags from /proc/cpuinfo
    if [[ "$supported" == false ]]; then
        if grep -q -E '^flags\s*:.*\b(avx2|bmi1|bmi2|fma)\b' /proc/cpuinfo; then
            # At least the most important v3 flags present
            supported=true
        fi
    fi

    if [[ "$supported" == true ]]; then
        success "x86_64_v3 is supported. Installation can proceed."
    else
        error "Your CPU does not support x86_64_v3. The CachyOS kernel is not suitable."
        warn "Use the regular Fedora kernel or the LTS kernel instead."
        pause
        return 1
    fi

    # 2. Set SELinux policy if active
    if [[ $(getenforce) != "Disabled" ]]; then
        info "SELinux is active. Setting required policy..."
        if sudo setsebool -P domain_kernel_load_modules on; then
            success "SELinux policy 'domain_kernel_load_modules' set."
        else
            error "Could not set SELinux policy. Aborting."
            pause
            return 1
        fi
    else
        info "SELinux is disabled - no additional policy needed."
    fi

    # 3. Add COPR Repos
    info "Adding CachyOS COPR Repositories..."
    if sudo dnf copr enable bieszczaders/kernel-cachyos -y && \
       sudo dnf copr enable bieszczaders/kernel-cachyos-addons -y; then
        success "COPR repos added successfully."
    else
        error "Error adding COPR repos. Aborting."
        pause
        return 1
    fi

    # 4. Install kernel
    info "Installing CachyOS kernel and developer packages..."
    sudo dnf install -y kernel-cachyos kernel-cachyos-devel

    success "Installation complete. A reboot is required to load the new kernel."
    pause
}

# --- RESTORE FROM BACKUP ---
restore_menu() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups"

    # Check if backups exist
    mapfile -t backups < <(ls -1dt "$base_dir"/backup_* 2>/dev/null)
    if [ ${#backups[@]} -eq 0 ]; then
        error "No backups found in folder $base_dir."
        pause
        return
    fi

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Restore from Backup ${NC}"
        sep
        echo -e "${YELLOW}Choose a backup to restore.${NC}"
        sep

        local idx=1
        for backup in "${backups[@]}"; do
            echo -e "${CYAN} $idx)${NC} $(basename "$backup")"
            ((idx++))
        done
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -rp "> " backup_choice

        if [[ "$backup_choice" -eq 0 ]]; then
            break
        elif [[ "$backup_choice" -ge 1 && "$backup_choice" -le ${#backups[@]} ]]; then
            local selected_backup="${backups[$((backup_choice-1))]}"
            restore_submenu "$selected_backup"
        else
            error "Invalid choice."
            pause
        fi
    done
}

# --- DESKTOP SETTINGS (Plasma, Dolphin, KWin) ---
desktop_settings_menu() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups/desktop-settings"

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Backup/Restore Desktop Settings ${NC}"
        sep
        echo -e "${YELLOW} Plasma, Dolphin, KWin – only selected config files${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Backup desktop settings"
        echo -e "${CYAN} 2)${NC} Restore desktop settings"
        sep
        echo -e "${CYAN} 0)${NC} Back"
        sep
        read -rp "> " dchoice
        case "$dchoice" in
            1) save_desktop_settings "$base_dir" ;;
            2) restore_desktop_settings "$base_dir" ;;
            0) break ;;
            *) error "Invalid choice."; pause ;;
        esac
    done
}

save_desktop_settings() {
    local base_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local target_dir="$base_dir/backup_$timestamp"

    mkdir -p "$target_dir"

    # List of desired files (relative to ~/.config)
    local files=(
        ".config/kdeglobals"
        ".config/kwinrc"
        ".config/plasma-org.kde.plasma.desktop-appletsrc"
        ".config/dolphinrc"
    )

    local any_copied=false
    for file in "${files[@]}"; do
        src="$user_home/$file"
        if [ -f "$src" ]; then
            cp "$src" "$target_dir/"
            echo -e "${GREEN}  → $(basename "$file") backed up${NC}"
            any_copied=true
        else
            echo -e "${YELLOW}  → $(basename "$file") not found (skipped)${NC}"
        fi
    done

    if $any_copied; then
        # Clean up old backups (max 5)
        local count=$(ls -1d "$base_dir"/backup_* 2>/dev/null | wc -l)
        if [[ $count -gt 5 ]]; then
            ls -1dt "$base_dir"/backup_* | tail -n +6 | xargs rm -rf
            echo -e "${YELLOW}Old backups (max 5) cleaned up.${NC}"
        fi
        success "Desktop settings backed up to: $target_dir"
    else
        error "None of the configuration files found – nothing backed up."
        rmdir "$target_dir" 2>/dev/null
    fi
    pause
}

restore_desktop_settings() {
    local base_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")

    # Check if backups exist
    mapfile -t backups < <(ls -1dt "$base_dir"/backup_* 2>/dev/null)
    if [ ${#backups[@]} -eq 0 ]; then
        error "No desktop backups found (Directory: $base_dir)."
        pause
        return
    fi

    # Select backup
    clear
    sep
    echo -e "${WHITE}${BOLD}   Restore desktop settings ${NC}"
    sep
    echo -e "${YELLOW}Select a backup:${NC}"
    local idx=1
    for backup in "${backups[@]}"; do
        echo -e "${CYAN} $idx)${NC} $(basename "$backup")"
        ((idx++))
    done
    sep
    echo -e "${CYAN} 0)${NC} Cancel"
    sep
    read -rp "> " choice

    if [[ "$choice" -eq 0 ]]; then
        return
    elif [[ "$choice" -ge 1 && "$choice" -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((choice-1))]}"

        echo -e "${YELLOW}The following files will be restored:${NC}"
        ls -1 "$selected_backup" | sed 's/^/  - /'
        echo -e "${YELLOW}Existing original files will be backed up beforehand (with .old).${NC}"
        read -rp "Perform restoration? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            local any_restored=false
            for file in "$selected_backup"/*; do
                filename=$(basename "$file")
                target="$user_home/.config/$filename"
                # Backup of the existing file
                if [ -f "$target" ]; then
                    cp "$target" "$target.old"
                    echo -e "${CYAN}  → Backed up $filename as .old${NC}"
                fi
                cp "$file" "$target"
                echo -e "${GREEN}  → $filename restored${NC}"
                any_restored=true
            done

            if $any_restored; then
                success "Desktop settings restored."
                echo -e "${YELLOW}Note: Some changes will only take effect after restarting Plasma.${NC}"
                echo -e "${YELLOW}You can run 'kwin_x11 --replace &' or 'plasmashell --replace &'.${NC}"
            fi
        else
            warn "Aborted."
        fi
    else
        error "Invalid choice."
    fi
    pause
}

# --- Submenu for a specific backup ---
restore_submenu() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Restore from: $(basename "$backup_dir") ${NC}"
        sep
        echo -e "${YELLOW}Select the data to restore.${NC}"
        echo -e "${YELLOW}Existing files in the destination will be overwritten if necessary.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} System configurations (fstab, dnf.conf, hosts, hostname, grub, bashrc, maint)"
        echo -e "${CYAN} 2)${NC} Restore package list (all DNF applications)"
        echo -e "${CYAN} 3)${NC} Firewall & Network (Firewall rules, Network connections)"
        echo -e "${CYAN} 4)${NC} Plasma Settings (Desktop configuration)"
        echo -e "${CYAN} 5)${NC} Cron Jobs (User and Root)"
        echo -e "${CYAN} 6)${NC} ALL (all categories above)"
        sep
        echo -e "${CYAN} 0)${NC} Back to backup selection"
        sep
        read -rp "> " restore_choice

        case "$restore_choice" in
            1) restore_system_configs "$backup_dir" ;;
            2) restore_packages "$backup_dir" ;;
            3) restore_network_firewall "$backup_dir" ;;
            4) restore_plasma_configs "$backup_dir" ;;
            5) restore_cron_jobs "$backup_dir" ;;
            6)
                restore_system_configs "$backup_dir"
                show_package_list "$backup_dir"
                restore_network_firewall "$backup_dir"
                restore_plasma_configs "$backup_dir"
                restore_cron_jobs "$backup_dir"
                success "All selected categories have been restored."
                pause
                ;;
            0) break ;;
            *) error "Invalid choice."; pause ;;
        esac
    done
}

# --- Helper functions for restoration ---
restore_system_configs() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local targets=(
        "/etc/fstab:$backup_dir/fstab"
        "/etc/dnf/dnf.conf:$backup_dir/dnf.conf"
        "/etc/hosts:$backup_dir/hosts"
        "/etc/hostname:$backup_dir/hostname"
        "/etc/default/grub:$backup_dir/grub"
        "$user_home/.bashrc:$backup_dir/.bashrc"
        "/usr/local/bin/maint:$backup_dir/maint"
    )

    echo -e "${YELLOW}Restoring system configurations...${NC}"
    local any_restored=false
    for entry in "${targets[@]}"; do
        target="${entry%:*}"
        source="${entry#*:}"
        if [ -f "$source" ]; then
            echo -e "${CYAN}File $target will be replaced?${NC}"
            read -rp "Restore? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # Create backup of existing file, if it exists
                if [ -f "$target" ]; then
                    sudo cp "$target" "$target.restore-backup" 2>/dev/null
                fi
                sudo cp "$source" "$target" 2>/dev/null
                echo -e "${GREEN}  -> $target restored${NC}"
                any_restored=true
            fi
        fi
    done

    if $any_restored && [[ -f "$backup_dir/grub" ]]; then
        echo -e "${YELLOW}GRUB configuration has changed. Regenerate GRUB? (y/N):${NC}"
        read -rp "> " gen_grub
        if [[ "$gen_grub" =~ ^[Yy]$ ]]; then
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            success "GRUB configuration updated."
        fi
    fi
    if ! $any_restored; then
        echo -e "${YELLOW}No system configurations restored.${NC}"
    fi
    pause
}

restore_packages() {
    local backup_dir="$1"
    local pkg_file="$backup_dir/installed-packages.txt"

    if [ ! -f "$pkg_file" ]; then
        warn "No package list found in backup."
        pause
        return
    fi

    echo -e "${YELLOW}All packages from the list will be installed.${NC}"
    echo -e "${YELLOW}This can take a very long time and may lead to conflicts,${NC}"
    echo -e "${YELLOW}since newer package versions might have been released in the meantime.${NC}"
    echo -e "${YELLOW}Recommendation: Make a current backup first!${NC}"
    sep
    echo -e "${CYAN}First 20 packages as preview:${NC}"
    head -n 20 "$pkg_file" | cat -n
    if [ $(wc -l < "$pkg_file") -gt 20 ]; then
        echo -e "${YELLOW}... and $(($(wc -l < "$pkg_file") - 20)) more.${NC}"
    fi
    sep
    read -rp "Do you really want to install the package list? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Starting installation of packages (this may take some time)..."
        # Option: --skip-broken, to continue if packages are missing
        sudo dnf install -y --skip-broken $(cat "$pkg_file")
        if [ $? -eq 0 ]; then
            success "All packages were successfully installed."
        else
            error "Errors occurred during installation. Check the output."
        fi
    else
        warn "Installation aborted."
    fi
    pause
}

restore_network_firewall() {
    local backup_dir="$1"
    local any_restored=false

    # Firewall rules (for viewing only)
    if [ -f "$backup_dir/firewall-rules.txt" ]; then
        echo -e "${YELLOW}Firewall rules (for viewing only):${NC}"
        cat "$backup_dir/firewall-rules.txt" | show_with_pager
    fi

    # Firewall zones
    if [ -d "$backup_dir/firewalld-zones" ] && [ -n "$(ls -A "$backup_dir/firewalld-zones" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Restore firewall zones? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo cp -r "$backup_dir/firewalld-zones"/* /etc/firewalld/zones/ 2>/dev/null
            sudo firewall-cmd --reload
            success "Firewall zones restored."
            any_restored=true
        fi
    fi

    # Network connections
    if [ -d "$backup_dir/network-connections" ] && [ -n "$(ls -A "$backup_dir/network-connections" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Restore network connections? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo cp -r "$backup_dir/network-connections"/* /etc/NetworkManager/system-connections/ 2>/dev/null
            sudo systemctl restart NetworkManager
            success "Network connections restored."
            any_restored=true
        fi
    fi

    if ! $any_restored; then
        echo -e "${YELLOW}No network/firewall configurations restored.${NC}"
    fi
    pause
}

restore_plasma_configs() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local plasma_dir="$backup_dir/plasma-configs"

    if [ -d "$plasma_dir" ] && [ -n "$(ls -A "$plasma_dir" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Restore Plasma settings? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Backup existing configuration
            mkdir -p "$user_home/.config/restore-backup"
            cp "$user_home/.config/kdeglobals" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/plasmashellrc" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/kwinrc" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/kactivitymanagerdrc" "$user_home/.config/restore-backup/" 2>/dev/null

            cp "$plasma_dir"/* "$user_home/.config/" 2>/dev/null
            success "Plasma settings restored."
            echo -e "${YELLOW}Note: Some changes will only take effect after a restart of the Plasma session.${NC}"
        else
            echo -e "${YELLOW}Skipped.${NC}"
        fi
    else
        warn "No Plasma settings found in backup."
    fi
    pause
}

restore_cron_jobs() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local any_restored=false

    # User-Crontab
    if [ -f "$backup_dir/crontab-user.txt" ]; then
        echo -e "${YELLOW}Restore User Crontab? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            crontab -l 2>/dev/null > "$user_home/crontab.backup"  # backup old
            crontab "$backup_dir/crontab-user.txt"
            success "User Crontab restored."
            any_restored=true
        fi
    fi

    # Root-Crontab
    if [ -f "$backup_dir/crontab-root.txt" ]; then
        echo -e "${YELLOW}Restore Root Crontab? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo crontab -l > /tmp/rootcrontab.backup 2>/dev/null
            sudo crontab "$backup_dir/crontab-root.txt"
            success "Root Crontab restored."
            any_restored=true
        fi
    fi

    if ! $any_restored; then
        echo -e "${YELLOW}No Cron jobs restored.${NC}"
    fi
    pause
}

# --- MAIN MENU ---
main_menu() {
    check_deps
    while true; do
                clear
        sep
        echo -e "${RED}${BOLD} ⚠️ WARNING: This script performs system changes${NC}"
        echo -e "${RED}${BOLD} ⚠️ WITHOUT further password prompts!${NC}"
        sep
        echo -e "${WHITE}${BOLD}    >>>>>> FEDORA 43 MAINTENANCE PRO v10.14.1 <<<<<<${NC}"
        sep

        echo -e "${WHITE}${BOLD}    [MAINTENANCE & UPDATES]${NC}"
        echo -e "${YELLOW} A) [AUTOPILOT]  Maintenance + Backup${NC}"
        echo -e "${YELLOW} B) [BACKUP]     Backup configurations (max. 5)${NC}"
        echo -e "${YELLOW} C) [RESTORE]    Restore from Backup${NC}"
        echo -e "${CYAN} 1)${NC} System Update (DNF)"
        echo -e "${CYAN} 2)${NC} Flatpak (Update/Repair/Management)"
        echo -e "${CYAN} 3)${NC} Firmware Updates (fwupd)"
        echo -e "${CYAN} 4)${NC} DNF (Cleanup/Search/Info)"
        echo -e "${CYAN} 5)${NC} Journal & Logs (Vacuum/Rotate)"
        echo -e "${CYAN} 6)${NC} Manage System Caches"
        echo -e "${CYAN} 7)${NC} Remove pre-installed apps (Bloatware)"
        sep

        echo -e "${WHITE}${BOLD}    [HARDWARE & DIAGNOSTICS]${NC}"
        echo -e "${CYAN} 8)${NC} SMART Hardware Check"
        echo -e "${CYAN} 9)${NC} SSD TRIM (All partitions)"
        echo -e "${CYAN}10)${NC} HDD Spindown (hd-idle) Control"
        echo -e "${CYAN}11)${NC} Btrfs Maintenance Menu"
        echo -e "${CYAN}12)${NC} System Health & Info"
        echo -e "${CYAN}13)${NC} Boot Time Analysis & Bootloader"
        echo -e "${CYAN}14)${NC} Stress Test & Monitoring"
        sep

        echo -e "${WHITE}${BOLD}    [TOOLS & MANAGEMENT]${NC}"
        echo -e "${CYAN} D)${NC} Desktop Settings (Plasma, Dolphin, KWin)"
        echo -e "${CYAN} R)${NC} Package Repair (RPM/DNF)"
        echo -e "${CYAN} N)${NC} Network Tools"
        echo -e "${CYAN} L)${NC} View Maintenance Logs"
        echo -e "${CYAN} K)${NC} Kernel Management"
        echo -e "${CYAN} S)${NC} Systemd Service Manager"
        sep

        echo -e "${CYAN} 0)${NC} Exit"
        sep

        read -rp "> " choice
        case "${choice,,}" in
                       a)
                clear
                sep
                echo -e "${WHITE}${BOLD}   Autopilot Maintenance ${NC}"
                sep
                echo -e "${YELLOW} The following actions will be performed:${NC}"
                echo -e "  • Backup of important configurations (max. 5 versions)"
                echo -e "  • DNF System Update (all packages)"
                echo -e "  • Flatpak Update & Repair & Remove unused"
                echo -e "  • Limit Journal Log to 200MB"
                echo -e "  • Execute Logrotate"
                echo -e "  • SSD TRIM on all drives"
                echo -e "  • Desktop notification at the end"
                sep
                read -rp " Do you want to start the Autopilot? (y/N): " auto_confirm
                if [[ "$auto_confirm" =~ ^[Yy]$ ]]; then
                    config_backup
                    sudo dnf upgrade --refresh -y
                    sudo flatpak update -y
                    sudo flatpak repair
                    sudo flatpak uninstall --unused -y
                    sudo journalctl --vacuum-size=200M
                    sudo logrotate /etc/logrotate.conf
                    sudo fstrim -av
                    send_notify "Autopilot Maintenance completed."
                    success "Autopilot done."
                else
                    warn "Autopilot aborted."
                fi
                pause ;;
            b) config_backup; pause ;;
            c) restore_menu ;;
            1) sudo dnf upgrade --refresh -y; pause ;;
            2) flatpak_management ;;
            3) clear; info "Searching for firmware updates..."; sudo fwupdmgr refresh && sudo fwupdmgr update; pause ;;
            4)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   DNF Cleanup & History ${NC}"
                    sep
                    echo -e "${YELLOW} Manages package transactions.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Autoremove     (Remove unneeded dependencies)"
                    echo -e "${CYAN} 2)${NC} Clean All      (Clears entire DNF package cache)"
                    echo -e "${CYAN} 3)${NC} History & Undo (allows rollbacks)"
                    echo -e "${CYAN} 4)${NC} Search installed packages (package name)"
                    echo -e "${CYAN} 5)${NC} Package details & actions (Remove, Reinstall etc.)"
                    sep
                    echo -e "${CYAN} 0)${NC} Back"
                    sep
                    read -p "> " dnf_choice
                    case "$dnf_choice" in
                        1) sudo dnf autoremove -y; success "Autoremove completed."; pause ;;
                        2)
                            echo -e "${YELLOW}This clears the entire DNF package cache.${NC}"
                            echo -e "${YELLOW}Packages will need to be downloaded again if required.${NC}"
                            read -rp "Really perform DNF Clean All? (y/N): " clean_confirm
                            if [[ "$clean_confirm" =~ ^[Yy]$ ]]; then
                                sudo dnf clean all
                                success "DNF Cache cleared."
                            else
                                warn "Aborted."
                            fi
                            pause ;;
                        3)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   DNF History & Undo ${NC}"
                            sep
                            sudo dnf history list | head -n 30
                            sep
                            echo -e "${YELLOW}Enter the ID of the transaction you want to undo.${NC}"
                            echo -e "${YELLOW}Empty input = return to menu.${NC}"
                            read -rp "ID: " tx
                            if [[ -n "$tx" ]]; then
                                clear
                                sep
                                echo -e "${WHITE}${BOLD}   Details for transaction $tx ${NC}"
                                sep
                                sudo dnf history info "$tx"
                                sep
                                echo -e "${YELLOW}Do you really want to undo this transaction?${NC}"
                                echo -e "${YELLOW}This will revert the package changes of this transaction.${NC}"
                                read -rp "Proceed? (y/N): " confirm
                                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                    info "Performing Undo for transaction $tx..."
                                    sudo dnf history undo -y "$tx"
                                    if [ $? -eq 0 ]; then
                                        success "Undo successfully completed."
                                    else
                                        error "Undo failed. See message above."
                                    fi
                                else
                                    warn "Undo aborted."
                                fi
                            fi
                            pause ;;
                        4)
                            echo -e "${YELLOW}Enter a search term (package name):${NC}"
                            read -rp "> " search_term
                            if [[ -z "$search_term" ]]; then
                                warn "No search term entered."
                                pause
                                continue
                            fi
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Search results for: $search_term ${NC}"
                            sep
                            # Only search package names (with rpm)
                            rpm -qa | grep -i "$search_term" | show_with_pager
                            if [ $? -ne 0 ]; then
                                echo -e "${YELLOW}No installed packages found with '$search_term' in the name.${NC}"
                            fi
                            pause
                            ;;
                        5)
                            echo -e "${YELLOW}Enter the exact package name (e.g., firefox, kernel):${NC}"
                            read -rp "> " pkg_name
                            if [[ -z "$pkg_name" ]]; then
                                warn "No name entered."
                                pause
                                continue
                            fi
                            # Check if package is installed
                            if ! rpm -q "$pkg_name" &>/dev/null; then
                                error "Package $pkg_name is not installed."
                                pause
                                continue
                            fi
                            while true; do
                                clear
                                sep
                                echo -e "${WHITE}${BOLD}   Package: $pkg_name ${NC}"
                                sep
                                echo -e "${CYAN} 1)${NC} Show information (dnf info)"
                                echo -e "${CYAN} 2)${NC} Show dependencies (required packages)"
                                echo -e "${CYAN} 3)${NC} Show dependent packages (packages that require this)"
                                echo -e "${CYAN} 4)${NC} Reinstall"
                                echo -e "${CYAN} 5)${NC} Remove"
                                sep
                                echo -e "${CYAN} 0)${NC} Back"
                                sep
                                read -p "> " pkg_action
                                case "$pkg_action" in
                                    1)
                                        clear
                                        sep
                                        echo -e "${WHITE}${BOLD}   Info: $pkg_name ${NC}"
                                        sep
                                        dnf info "$pkg_name" | show_with_pager
                                        pause
                                        ;;
                                    2)
                                        clear
                                        sep
                                        echo -e "${WHITE}${BOLD}   Required dependencies for $pkg_name ${NC}"
                                        sep
                                        dnf repoquery --requires --installed "$pkg_name" | show_with_pager
                                        pause
                                        ;;
                                    3)
                                        clear
                                        sep
                                        echo -e "${WHITE}${BOLD}   Packages requiring $pkg_name ${NC}"
                                        sep
                                        dnf repoquery --whatrequires --installed "$pkg_name" | show_with_pager
                                        pause
                                        ;;
                                    4)
                                        echo -e "${YELLOW}Perform reinstallation of $pkg_name? (y/N):${NC}"
                                        read -rp "> " reinstall_confirm
                                        if [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                                            sudo dnf reinstall -y "$pkg_name"
                                            success "$pkg_name reinstalled."
                                        else
                                            warn "Aborted."
                                        fi
                                        pause
                                        ;;
                                    5)
                                        echo -e "${RED}${BOLD}WARNING: Removing $pkg_name${NC}"
                                        echo -e "${YELLOW}This can destabilize the system if these are important dependencies.${NC}"
                                        read -rp "Really remove? (y/N): " remove_confirm
                                        if [[ "$remove_confirm" =~ ^[Yy]$ ]]; then
                                            sudo dnf remove -y "$pkg_name"
                                            if [ $? -eq 0 ]; then
                                                success "$pkg_name removed."
                                                # Return to main DNF menu after removal
                                                break
                                            else
                                                error "Removal failed."
                                            fi
                                        else
                                            warn "Aborted."
                                        fi
                                        pause
                                        ;;
                                    0) break ;;
                                    *) error "Invalid choice."; pause ;;
                                esac
                            done
                            ;;
                        0) break ;;
                    esac
                done ;;
            5) sudo journalctl --vacuum-size=200M; info "Starting Logrotate..."; sudo logrotate /etc/logrotate.conf && success "Logrotate executed."; pause ;;
            6)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Manage System Caches ${NC}"
                    sep
                    echo -e "${YELLOW} Deletes temporary files${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Clear Gaming Caches (Vulkan/Shader)"
                    echo -e "${CYAN} 2)${NC} Complete User Cache (.cache/)"
                    sep
                    echo -e "${CYAN} 0)${NC} Back"
                    sep
                    read -p "> " c_choice
                    case "$c_choice" in
                        1) rm -rf "$HOME/.cache/vulkan" "$HOME/.cache/gl_shader" 2>/dev/null; success "Gaming Caches cleared."; pause ;;
                                              2)
                            echo -e "${YELLOW}${BOLD}WARNING: Deletes the entire .cache folder!${NC}"
                            echo -e "${YELLOW}This affects temporary files of applications (e.g., browser cache,${NC}"
                            echo -e "${YELLOW}thumbnails, package manager caches). Your personal documents,${NC}"
                            echo -e "${YELLOW}downloads, pictures, videos etc. will be preserved.${NC}"
                            read -rp "Delete the entire User Cache anyway? (y/N): " cache_conf
                            if [[ "$cache_conf" =~ ^[Yy]$ ]]; then
                                rm -rf "$HOME/.cache/"*
                                success "User Cache cleared."
                            else
                                warn "Aborted."
                            fi
                            pause ;;
                        0) break ;;
                    esac
                done ;;
                          7)
                while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Remove pre-installed apps (Bloatware) ${NC}"
                 sep
                 echo -e "${YELLOW} Uninstalls unused standard programs${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} Games & Entertainment"
                 echo -e "${CYAN} 2)${NC} KDE PIM / Akonadi"
                 echo -e "${CYAN} 3)${NC} Software Center & Package Management"
                 echo -e "${CYAN} 4)${NC} Network & Remote"
                 echo -e "${CYAN} 5)${NC} KDE Utilities & System Tools"
                 echo -e "${CYAN} 6)${NC} VM Guests & Installation Helpers"
                 sep
                 echo -e "${CYAN} 0)${NC} Back"
                 sep
                 read -p "> " uchoice
                 case "$uchoice" in
                   1) confirm_and_remove "Games & Entertainment" "kmines kmahjongg kpat elisa-player neochat gwenview dragon kamoso" ;;
                   2) confirm_and_remove "KDE PIM / Akonadi" "akonadi* kdepim-* kleopatra korganizer incidenceeditor akregator kmail kaddressbook" ;;
                   3) confirm_and_remove "Software Center" "plasma-discover plasma-discover-flatpak plasma-discover-kns plasma-discover-libs plasma-discover-notifier plasma-discover-offline-updates plasma-discover-packagekit flatpak-kcm" ;;
                   4) confirm_and_remove "Network & Remote" "kde-connect krdc krdc-libs krfb krfb-libs krdp krdp-libs kdenetwork-filesharing kio-gdrive" ;;
                   5) confirm_and_remove "KDE Utilities" "mediawriter kamera kcharselect kfind kolourpaint kolourpaint-libs kasumi-common kasumi-unicode khelpcenter plasma-systemmonitor kactivitymanagerd kscreen kscreenlocker ksysguard ksysguardd kded kded5 kdebugsettings kwrite plasma-welcome qrca skanpage kmouth" ;;
                   6) confirm_and_remove "VM Guests & Installation Helpers" "virtualbox-guest-additions open-vm-tools-desktop anaconda-install-env-deps anaconda-live initial-setup-gui initial-setup-gui-wayland-plasma livesys-scripts anaconda-core anaconda-tui anaconda-webui" ;;
                   0) break ;;
                   *) error "Invalid choice."; pause ;;
                 esac
                done ;;
            8) smart_disk_check ;;
                        9)
               info "Checking hardware for TRIM..."
               RAW_SOURCE=$(findmnt -no SOURCE /)
               CLEAN_DEV=$(echo "$RAW_SOURCE" | sed 's/\[.*\]//' | xargs basename)
               PARENT_DEV=$(lsblk -no PKNAME "/dev/$CLEAN_DEV" 2>/dev/null | head -n1 | xargs)
               [[ -z "$PARENT_DEV" ]] && PARENT_DEV="$CLEAN_DEV"

               # Check if the path /sys/block/.../queue/rotational exists
               if [[ ! -f "/sys/block/$PARENT_DEV/queue/rotational" ]]; then
                   warn "Cannot determine if it's an SSD/HDD. Skipping TRIM."
               elif [[ $(cat "/sys/block/$PARENT_DEV/queue/rotational" 2>/dev/null) == "0" ]]; then
                   sudo fstrim -av
                   success "TRIM executed."
               else
                   warn "HDD detected. TRIM will not be executed (not necessary)."
               fi
               pause ;;
            10) manage_hd_idle ;;
            11)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Btrfs Maintenance Menu ${NC}"
                    sep
                    echo -e "${YELLOW} Maintenance of the Btrfs filesystem of the root partition.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Start Scrub   (Filesystem error check)"
                    echo -e "${CYAN} 2)${NC} Scrub Status    (Show progress of the check)"
                    echo -e "${CYAN} 3)${NC} Balance (gentle) (Rearrange data for more space)"
                    sep
                    echo -e "${CYAN} 0)${NC} Back"
                    sep
                    read -p "> " btrfs_choice
                    case "$btrfs_choice" in
                        1) sudo btrfs scrub start /; success "Scrub started."; pause ;;
                        2) sudo btrfs scrub status / | show_with_pager; pause ;;
                                               3)
                            echo -e "${YELLOW}Note: A balance can take a long time depending on the amount of data${NC}"
                            echo -e "${YELLOW}and stress the disk. It is generally safe, but${NC}"
                            echo -e "${YELLOW}it is recommended to have a backup of important data first.${NC}"
                            read -rp "Start Balance? (y/N): " balance_confirm
                            if [[ "$balance_confirm" =~ ^[Yy]$ ]]; then
                                sudo btrfs balance start -dusage=10 -musage=10 /
                                success "Balance executed."
                            else
                                warn "Aborted."
                            fi
                            pause ;;
                        0) break ;;
                    esac
                done ;;
               12)
               clear
               sep
               echo -e "${WHITE}${BOLD}   System Health & Info ${NC}"
               sep
               echo -e "${YELLOW} Overview of critical system states${NC}"
               sep
               echo -e "${BOLD}Failed Services:${NC}"
               failed_services=$(systemctl list-units --state=failed --no-legend 2>/dev/null)
               if [ -z "$failed_services" ]; then
                   echo "Everything is okay."
               else
                   echo "$failed_services"
               fi
               echo -e "\n${BOLD}Storage Usage:${NC}"; df -h -t ext4 -t xfs -t btrfs
               echo -e "\n${BOLD}SELinux Status:${NC}"; getenforce
               echo -e "\n${BOLD}Firewall Status:${NC}"; systemctl is-active firewalld

               echo -e "\n${BOLD}Display Server (Wayland/X11):${NC}"
               loginctl list-sessions | awk '/seat/ {print $1}' | head -n1 | xargs -I {} loginctl show-session {} -p Type --value 2>/dev/null || echo "Unknown"

               sep

               # Submenu for additional system information
               while true; do
                    echo -e "${CYAN}More Options:${NC}"
                    echo -e "${CYAN} 1)${NC} Show recent SELinux denials"
                    echo -e "${CYAN} 2)${NC} Hardware Overview (inxi)"
                    echo -e "${CYAN} 3)${NC} Detailed HTML Hardware Report (lshw)"
                    echo -e "${CYAN} 0)${NC} Back to main menu"
                    read -rp "Your choice: " health_choice
                    case "$health_choice" in
                        1)
                            info "Showing recent SELinux denials..."
                            sudo SYSTEMD_COLORS=1 journalctl -t setroubleshoot -n 20 --no-pager | show_with_pager
                            pause
                            ;;
                        2)
                            # Check if inxi is installed
                            if ! command -v inxi >/dev/null 2>&1; then
                                echo -e "${YELLOW}inxi is not installed. Do you want to install it? (y/N):${NC}"
                                read -rp "> " inst_inxi
                                if [[ "$inst_inxi" =~ ^[Yy]$ ]]; then
                                    sudo dnf install -y inxi
                                else
                                    warn "Installation aborted."
                                    pause
                                    continue
                                fi
                            fi
                            ask_and_start "inxi -Fxxxrz" "inxi"
                            ;;
                        3)
                            # Check if lshw is installed
                            if ! command -v lshw >/dev/null 2>&1; then
                                echo -e "${YELLOW}lshw is not installed. Do you want to install it? (y/N):${NC}"
                                read -rp "> " inst_lshw
                                if [[ "$inst_lshw" =~ ^[Yy]$ ]]; then
                                    sudo dnf install -y lshw
                                else
                                    warn "Installation aborted."
                                    pause
                                    continue
                                fi
                            fi
                            local user_home=$(eval echo "~${SUDO_USER:-$USER}")
                            local report_file="$user_home/hardware-report.html"
                            info "Generating HTML report with lshw (requires sudo)..."
                            sudo lshw -html > "$report_file"
                            sudo chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$report_file"
                            success "Report generated: $report_file"
                            echo -e "${YELLOW}You can open it with a browser.${NC}"
                            pause
                            ;;
                        0)
                            break
                            ;;
                        *)
                            error "Invalid choice."
                            ;;
                    esac
                    echo ""
               done
               pause ;;
                        13)
               while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Boot Time Analysis & Bootloader ${NC}"
                    sep
                    echo -e "${YELLOW} Analyzes boot time and adjusts GRUB.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Boot Time Analysis (systemd-analyze)"
                    echo -e "${CYAN} 2)${NC} Adjust GRUB Boot Behavior"
                    sep
                    echo -e "${CYAN} 0)${NC} Back"
                    sep
                    read -rp "> " boot_choice
                    case "$boot_choice" in
                        1)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Boot Time Analysis ${NC}"
                            sep
                            systemd-analyze
                            echo -e "\n${YELLOW}Time breakdown of services (Top 20):${NC}"
                            systemd-analyze blame | head -n 20
                            sep
                            pause
                            ;;
                        2)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Adjust GRUB Boot Behavior ${NC}"
                            sep
                            echo -e "${YELLOW}Determines if the GRUB menu is shown on startup and for how long.${NC}"
                            sep
                            echo -e "${CYAN} 1)${NC} Menu always visible (with timeout)"
                            echo -e "${CYAN} 2)${NC} Auto-hide menu (only when needed)"
                            read -rp "Choice (1/2): " grub_mode

                            local timeout_value=""
                            if [[ "$grub_mode" == "1" ]]; then
                                read -rp "Timeout in seconds (default 5): " timeout_input
                                timeout_value=${timeout_input:-5}
                                # GRUB_TIMEOUT_STYLE=menu
                                sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
                            else
                                read -rp "Timeout in seconds (0 = boot immediately, default 2): " timeout_input
                                timeout_value=${timeout_input:-2}
                                # GRUB_TIMEOUT_STYLE=hidden
                                sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
                            fi

                            # Set GRUB_TIMEOUT
                            sudo sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$timeout_value/" /etc/default/grub

                            # Append lines if they don't exist
                            if ! grep -q "^GRUB_TIMEOUT_STYLE=" /etc/default/grub; then
                                if [[ "$grub_mode" == "1" ]]; then
                                    echo 'GRUB_TIMEOUT_STYLE=menu' | sudo tee -a /etc/default/grub
                                else
                                    echo 'GRUB_TIMEOUT_STYLE=hidden' | sudo tee -a /etc/default/grub
                                fi
                            fi
                            if ! grep -q "^GRUB_TIMEOUT=" /etc/default/grub; then
                                echo "GRUB_TIMEOUT=$timeout_value" | sudo tee -a /etc/default/grub
                            fi

                            echo -e "${YELLOW}Generating new GRUB configuration...${NC}"
                            sudo grub2-mkconfig -o /boot/grub2/grub.cfg
                            success "GRUB configuration updated."
                            echo -e "${YELLOW}The change will take effect on the next reboot.${NC}"
                            pause
                            ;;
                        0) break ;;
                        *) error "Invalid choice."; pause ;;
                    esac
               done ;;
            14)

               # Dependency check for stress tests
               local s_missing=()
               command -v s-tui >/dev/null 2>&1 || s_missing+=("s-tui")
               command -v memtester >/dev/null 2>&1 || s_missing+=("memtester")
               command -v stress-ng >/dev/null 2>&1 || s_missing+=("stress-ng")

               if [ ${#s_missing[@]} -ne 0 ]; then
                   echo -e "${YELLOW}[INFO] Additional tools are required for stress testing:${NC}"
                   for item in "${s_missing[@]}"; do echo -e "  - $item"; done
                   read -rp "Do you want to install them now? (y/N): " s_choice
                   if [[ "$s_choice" =~ ^[Yy]$ ]]; then
                       sudo dnf install -y "${s_missing[@]}"
                   else
                       warn "Installation aborted. Returning to main menu."
                       pause
                       continue
                   fi
               fi

               while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Stress Test & Monitoring ${NC}"
                    sep
                    echo -e "${YELLOW} Check system stability and hardware load.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} s-tui (CPU Monitoring & Stress GUI)"
                    echo -e "${CYAN} 2)${NC} memtester (Memory Stability Test)"
                    echo -e "${CYAN} 3)${NC} stress-ng (Advanced System Stress Test)"
                    sep
                    echo -e "${CYAN} 0)${NC} Back"
                    sep
                    read -p "> " st_choice
                    case "$st_choice" in
                            1)
                            info "Starting s-tui..."
                            ask_and_start "sudo s-tui" "s-tui"
                            success "s-tui started."
                            ;;
                            2)
                            read -rp "How much RAM should be tested? (e.g., 1024M or 2G): " m_ram
                            read -rp "How many passes?: " m_runs
                            info "Starting memtester..."
                            ask_and_start "sudo memtester \"$m_ram\" \"$m_runs\"" "memtester"
                            success "memtester started."
                            ;;
                            3)
                            # Automatically determine number of CPU threads
                            local cpu_threads=$(nproc)
                            read -rp "Duration of the test (e.g., 60s, 5m, 1h): " s_time
                            echo -e "Which test should be executed?"
                            echo -e " 1) CPU Intensive (Integer, all cores) – good for initial stability"
                            echo -e " 2) FPU + Cache (Matrix, L3) – optimal for Curve Optimizer"
                            echo -e " 3) RAM & Cache – checks memory controller and Infinity Fabric"
                            read -rp "Choice (1/2/3): " test_wahl

                            local test_cmd=""
                            case $test_wahl in
                                1)
                                    test_cmd="sudo stress-ng --cpu $cpu_threads --timeout $s_time --verify --verbose"
                                    ;;
                                2)
                                    test_cmd="sudo stress-ng --matrix $cpu_threads --cache $cpu_threads --timeout $s_time --verify --verbose"
                                    ;;
                                3)
                                    # For RAM test: fewer workers, but high memory utilization
                                    test_cmd="sudo stress-ng --vm 4 --vm-bytes 80% --cache 8 --timeout $s_time --verify --verbose"
                                    ;;
                                *)
                                    error "Invalid choice"
                                    pause
                                    continue
                                    ;;
                            esac

                            info "Starting stress-ng with: $test_cmd"
                            ask_and_start "$test_cmd" "stress-ng"
                            success "stress-ng started."
                            ;;
                        0) break ;;
                        *) error "Invalid choice."; pause ;;
                    esac
               done ;;
            d) desktop_settings_menu ;;
            r) while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Package Repair Tools ${NC}"
                 sep
                 echo -e "${YELLOW} Helps with package management issues (DNF/RPM).${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} DNF Check        (Checks dependencies for errors)"
                 echo -e "${CYAN} 2)${NC} Search duplicates (Finds duplicate packages)"
                 echo -e "${CYAN} 3)${NC} RPM DB Rebuild   (Repairs RPM database)"
                 echo -e "${CYAN} 4)${NC} RPM Verify (-Va) (Compares files with originals)"
                 sep
                 echo -e "${CYAN} 0)${NC} Back"
                 sep
                 read -p "> " r1
                 case $r1 in
                   1) info "Starting DNF Check..."; sudo dnf check && success "DNF Check completed."; pause ;;
                   2) info "Searching for duplicates..."; sudo dnf repoquery --duplicates || success "No duplicates found."; pause ;;
                                      3)
                       echo -e "${YELLOW}Rebuilding the RPM database is normally safe,${NC}"
                       echo -e "${YELLOW}but can cause short locks during operation.${NC}"
                       read -rp "Perform RPM DB Rebuild? (y/N): " rpm_confirm
                       if [[ "$rpm_confirm" =~ ^[Yy]$ ]]; then
                           info "RPM DB Rebuild..."; sudo rpm --rebuilddb && success "RPM database rebuilt."
                       else
                           warn "Aborted."
                       fi
                       pause ;;
                   4) info "RPM Verify running..."; sudo rpm -Va | show_with_pager; success "Verification finished."; pause ;;
                   0) break ;;
                 esac
               done ;;
            s) service_manager ;;
            n) while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Network Tools ${NC}"
                 sep
                 echo -e "${YELLOW} Useful tools for diagnosing network connection.${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} IP Addresses     (Local & External)"
                 echo -e "${CYAN} 2)${NC} Flush DNS Cache  (For name resolution issues)"
                 echo -e "${CYAN} 3)${NC} Open Ports       (Shows listening services/sockets)"
                 echo -e "${CYAN} 4)${NC} nethogs          (Network bandwidth per process)"
                 echo -e "${CYAN} 5)${NC} nload            (Network utilization in real-time)"
                 sep
                 echo -e "${CYAN} 0)${NC} Back"
                 sep
                 read -p "> " n1
                 case $n1 in
                   1) echo -en "Local: "; hostname -I; echo -en "External: "; curl -s https://ifconfig.me; echo ""; pause ;;
                   2) info "Flushing DNS Cache..."; sudo resolvectl flush-caches && success "DNS Cache flushed."; pause ;;
                   3) info "Showing open ports..."; sudo ss -tulpn | grep LISTEN | show_with_pager; pause ;;
                   4)
                       # Check if nethogs is installed
                       if ! command -v nethogs >/dev/null 2>&1; then
                           echo -e "${YELLOW}nethogs is not installed. Do you want to install it? (y/N):${NC}"
                           read -rp "> " inst_nethogs
                           if [[ "$inst_nethogs" =~ ^[Yy]$ ]]; then
                               sudo dnf install -y nethogs
                           else
                               warn "Installation aborted. Returning."
                               pause
                               continue
                           fi
                       fi
                       # Mode selection
                       echo -e "${YELLOW}Which mode?${NC}"
                       echo -e " 1) Normal mode (shows current connections)"
                       echo -e " 2) Trace mode (also shows packet traces)"
                       read -rp "Choice (1/2): " mode
                       if [[ "$mode" == "2" ]]; then
                           nethogs_cmd="sudo nethogs -t"
                       else
                           nethogs_cmd="sudo nethogs"
                       fi
                       # Show hint
                       echo -e "${CYAN}${BOLD}Note on nethogs:${NC}"
                       echo -e "  - Toggle between kb/s, kb, b, mb: press ${WHITE}${BOLD}m${NC}"
                       echo -e "  - Sort by Rx/Tx: press ${WHITE}${BOLD}s${NC} (repeatedly)"
                       echo -e "  - Quit: ${WHITE}${BOLD}q${NC}"
                       ask_and_start "$nethogs_cmd" "nethogs"
                       ;;
                    5)
                       # Check if nload is installed
                       if ! command -v nload >/dev/null 2>&1; then
                           echo -e "${YELLOW}nload is not installed. Do you want to install it? (y/N):${NC}"
                           read -rp "> " inst_nload
                           if [[ "$inst_nload" =~ ^[Yy]$ ]]; then
                               sudo dnf install -y nload
                           else
                               warn "Installation aborted. Returning."
                               pause
                               continue
                           fi
                       fi
                       # Settings for nload
                       echo -e "${YELLOW}Settings for nload:${NC}"
                       read -rp "Refresh rate in milliseconds (default 500): " refresh
                       refresh=${refresh:-500}
                       echo -e "Unit for display:"
                       echo -e " 1) Bytes"
                       echo -e " 2) Bits"
                       read -rp "Choice (1/2): " unit_choice
                       if [[ "$unit_choice" == "2" ]]; then
                           unit_flag="-u B"   # nload -u B = Bits
                       else
                           unit_flag="-u b"   # nload -u b = Bytes
                       fi
                       ask_and_start "nload -t $refresh $unit_flag" "nload"
                            ;;
                   0) break ;;
                 esac
               done ;;
            l)
                clear
                sep
                echo -e "${WHITE}${BOLD}   View Maintenance Logs ${NC}"
                sep
                echo -e "${YELLOW} Shows the logs of past maintenance runs${NC}"
                sep
                mapfile -t FILES < <(sudo ls -1t "$SYS_LOG_DIR"/maintenance-*.log 2>/dev/null)
                for i in "${!FILES[@]}"; do printf "${CYAN} %d)${NC} %s\n" "$((i+1))" "$(basename "${FILES[i]}")"; done
                sep
                sep
                read -rp "Choice (d=delete, 0=back): " sel
                if [[ "$sel" == "d" ]]; then sudo rm -f "$SYS_LOG_DIR"/*.log; elif [[ "$sel" =~ ^[0-9]+$ && "$sel" -gt 0 ]]; then sudo cat "${FILES[sel-1]}" | show_with_pager; fi; pause ;;
            k) kernel_menu ;;
            0) exit 0 ;;
            *) error "Invalid."; sleep 1 ;;
        esac
    done
}

# Installation check
if [[ "$0" != "/usr/local/bin/maint" && ! -f "/usr/local/bin/maint" ]]; then
    read -rp "Install as 'maint'? [y/N]: " inst
    [[ "$inst" =~ ^[Yy]$ ]] && sudo cp "$0" /usr/local/bin/maint && sudo chmod +x /usr/local/bin/maint && success "Installed!" && pause
fi

# Root rights check
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Please run with 'sudo'.${NC}"
    exit 1
fi

main_menu
