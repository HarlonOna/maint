#!/usr/bin/env bash
###############################################################################
# Script Name:   # maint (Fedora Maintenance Pro)
# Description:   # Umfassendes Wartungs- und Diagnose-Tool für Fedora Linux.
#                # Beinhaltet Backups, Kernel-Optimierung, Hardware-Checks und mehr.
# Author:        # HarlonOna
# Version:       # 10.14.0
# License:       # GPL-3.0
# GitHub:        # https://github.com/HarlonOna/maint/
###############################################################################

set -uo pipefail
IFS=$'\n\t'

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'
ESC=$(printf '\033')

# --- Einheitliche Trennlinien ---
SEP_LINE="${MAGENTA}========================================================${NC}"
sep() { echo -e "$SEP_LINE"; }

# --- ABHÄNGIGKEITEN PRÜFEN ---
check_deps() {
    local missing=()
    command -v smartctl >/dev/null 2>&1 || missing+=("smartmontools")
    command -v curl >/dev/null 2>&1     || missing+=("curl")
    command -v flatpak >/dev/null 2>&1  || missing+=("flatpak")
    command -v hd-idle >/dev/null 2>&1  || missing+=("hd-idle")
    command -v fwupdmgr >/dev/null 2>&1 || missing+=("fwupd")

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${YELLOW} [WARN] Folgende Programme fehlen:${NC}"
        for item in "${missing[@]}"; do echo -e "  - $item"; done
        read -rp "Möchten Sie diese jetzt installieren? (y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            # Sonderfall hd-idle: möglicherweise nicht in Standard-Repos
            if [[ " ${missing[@]} " =~ " hd-idle " ]]; then
                # Prüfen, ob hd-idle in den aktiven Repos verfügbar ist
                if ! dnf list available hd-idle &>/dev/null; then
                    echo -e "${YELLOW}hd-idle ist nicht in den Standard-Repos. Versuche RPM Fusion zu aktivieren...${NC}"
                    # RPM Fusion free aktivieren, falls nicht vorhanden
                    if ! dnf repolist | grep -q "rpmfusion-free"; then
                        sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
                    fi
                fi
            fi
            sudo dnf install -y "${missing[@]}"
        else
            echo -e "${RED}Einige Funktionen werden nicht korrekt arbeiten.${NC}"
            sleep 2
        fi
    fi
}

# Log-Vorbereitung
SYS_LOG_DIR="/var/log/sys-maintenance"
[[ ! -d "$SYS_LOG_DIR" ]] && sudo mkdir -p "$SYS_LOG_DIR" 2>/dev/null
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$SYS_LOG_DIR/maintenance-$TIMESTAMP.log"

# Desktop-Benachrichtigung
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
pause() { echo -en "${CYAN} Drücke [Enter] zum Fortsetzen...${NC}"; read -r; }
show_with_pager() { if command -v less >/dev/null 2>&1; then LESS=FRX less -R; else cat; fi; }

# --- Terminal-Start-Funktion (mit automatischem Fallback bei fehlendem Monitor) ---
# Aufruf: start_in_terminal "befehl" [same_window]
# same_window = "true" => Ausführung im aktuellen Terminal (blockiert)
# andernfalls: automatische Entscheidung (neues Fenster wenn möglich, sonst aktuell)
start_in_terminal() {
    local cmd="$1"
    local force_same="${2:-false}"

    # Wenn gewünscht oder keine GUI verfügbar, direkt im aktuellen Terminal ausführen
    if [[ "$force_same" == "true" ]] || [[ -z "${DISPLAY:-}" ]]; then
        if [[ -z "${DISPLAY:-}" ]]; then
            echo -e "${YELLOW}Keine grafische Umgebung erkannt – führe Befehl im aktuellen Terminal aus.${NC}"
        fi
        eval "$cmd"
        echo -e "\n${CYAN}Drücke Enter, um fortzufahren...${NC}"
        read -r
        return 0
    fi

    # GUI vorhanden – versuche, einen Terminal-Emulator zu finden
    if command -v konsole >/dev/null 2>&1; then
        konsole -e bash -c "$cmd" &
    elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -c "$cmd" &
    elif command -v xterm >/dev/null 2>&1; then
        xterm -e bash -c "$cmd" &
    else
        echo -e "${YELLOW}Kein Terminal-Emulator gefunden – führe Befehl im aktuellen Terminal aus.${NC}"
        eval "$cmd"
        echo -e "\n${CYAN}Drücke Enter, um fortzufahren...${NC}"
        read -r
    fi
    sleep 1

}

# --- Einheitliche Abfrage: Neues Terminal oder aktuell? ---
# Aufruf: ask_and_start "befehl" "beschreibung" [default_new]
# beschreibung: wird im Menütext angezeigt (z.B. "s-tui")
# default_new: wenn "true", wird Option 2 (neues Terminal) als Standard vorgeschlagen
ask_and_start() {
    local cmd="$1"
    local desc="$2"
    local default_new="${3:-false}"

    echo -e "${YELLOW}Starte $desc im aktuellen Terminal oder in einem neuen Fenster?${NC}"
    echo -e " 1) Aktuelles Terminal (blockiert das Skript bis zum Beenden)"
    echo -e " 2) Neues Terminal-Fenster (läuft im Hintergrund)"

    local prompt="Wahl (1/2): "
    if [[ "$default_new" == "true" ]]; then
        prompt="Wahl (1/2) [2]: "
    fi
    read -rp "$prompt" term_choice

    if [[ "$term_choice" == "1" ]]; then
        start_in_terminal "$cmd" "true"
    elif [[ "$term_choice" == "2" ]] || [[ -z "$term_choice" && "$default_new" == "true" ]]; then
        start_in_terminal "$cmd"
    else
        warn "Ungültige Auswahl. Starte im aktuellen Terminal."
        start_in_terminal "$cmd" "true"
    fi
}

# --- UNINSTALLER ---
confirm_and_remove() {
    local category_name="$1"; local packages="$2"
    clear
    sep
    echo -e "${WHITE}${BOLD}   Kategorie: $category_name ${NC}"
    sep
    echo -e "${YELLOW}Vorschlag zur Deinstallation:${NC}\n$packages" | tr ' ' '\n' | sed 's/^/  - /'
    sep
    read -rp "Entfernen? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && { info "Deinstalliere..."; sudo dnf remove -y $packages; success "Fertig."; } || warn "Abgebrochen."
    pause
}

# --- HD-IDLE STEUERUNG (dauerhafter Daemon mit -n) ---
manage_hd_idle() {
    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   HDD Spindown (hd-idle) Steuerung ${NC}"
        sep
        echo -e "${YELLOW} Schaltet mechanische Festplatten bei Inaktivität ab,${NC}"
        echo -e "${YELLOW} um Strom zu sparen und die Lebensdauer zu verlängern.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} HDD wählen & Spindown-Timer setzen"
        echo -e "${CYAN} 2)${NC} Aktueller Status & Config     (hd-idle läuft?)"
        echo -e "${CYAN} 3)${NC} hd-idle komplett deaktivieren (Stoppt den Service)"
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
        sep
        read -p "> " hchoice
        case "$hchoice" in
            1)
                info "Suche nach HDDs..."
                mapfile -t HDDS < <(lsblk -dn -o NAME,ROTA | grep " 1$" | awk '{print "/dev/"$1}')
                if [ ${#HDDS[@]} -eq 0 ]; then
                    error "Keine mechanischen HDDs gefunden!"
                    pause; continue
                fi
                for i in "${!HDDS[@]}"; do echo -e "${CYAN}$((i+1)))${NC} ${HDDS[i]}"; done
                read -rp "Wahl: " hsel
                if [[ "$hsel" -gt 0 && "$hsel" -le "${#HDDS[@]}" ]]; then
                    DEV_PATH="${HDDS[hsel-1]}"
                    DEV_NAME=$(basename "$DEV_PATH")
                    read -rp "Inaktivität bis Spindown (in Minuten, Standard 10): " mins
                    mins=${mins:-10}
                    secs=$((mins * 60))

                    # Override-Datei mit -n (Vordergrund) und explizitem Service-Typ
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

                    # Prüfen, ob der Dienst aktiv ist
                    sleep 2
                    if systemctl is-active --quiet hd-idle; then
                        success "Timer auf $mins Min gesetzt für $DEV_NAME. Dienst läuft."
                    else
                        error "Dienst konnte nicht gestartet werden. Prüfe Logs mit: journalctl -u hd-idle"
                    fi
                fi; pause ;;
            2)
                echo -e "${YELLOW}Konfiguration:${NC}"
                [ -f /etc/systemd/system/hd-idle.service.d/override.conf ] && cat /etc/systemd/system/hd-idle.service.d/override.conf || echo "Keine Config."
                echo -e "\n${YELLOW}Status:${NC}"
                if systemctl is-active --quiet hd-idle; then
                    echo -e "${GREEN}aktiv${NC}"
                    # Versuche, den Zustand der konfigurierten Platte zu ermitteln
                    local cfg_dev=$(grep -oP '(?<=-a )[^ ]+' /etc/systemd/system/hd-idle.service.d/override.conf 2>/dev/null)
                    if [[ -n "$cfg_dev" ]]; then
                        local state=$(sudo hdparm -C "/dev/$cfg_dev" 2>/dev/null | grep -o 'drive state is: [a-z]*')
                        echo -e "\n${YELLOW}Zustand von /dev/$cfg_dev:${NC} ${state:-unbekannt}"
                    fi
                else
                    echo -e "${RED}inaktiv${NC}"
                fi
                echo -e "\n${YELLOW}Log-Auszug (letzte 5 Zeilen):${NC}"
                sudo journalctl -u hd-idle -n 5 --no-pager
                pause ;;
            3)
                sudo systemctl disable --now hd-idle
                sudo rm -rf /etc/systemd/system/hd-idle.service.d
                sudo systemctl daemon-reload
                success "hd-idle deaktiviert und Konfiguration entfernt."; pause ;;
            0) break ;;
        esac
    done
}

# --- BACKUP (erweitert) ---
config_backup() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups"
    local current_bak="$base_dir/backup_$TIMESTAMP"
    mkdir -p "$current_bak"

    # 1. Standard-Konfigs (wie bisher)
    local files=("/etc/fstab" "/etc/dnf/dnf.conf" "/etc/hosts" "/etc/hostname" "/etc/default/grub" "$user_home/.bashrc" "/usr/local/bin/maint")
    for f in "${files[@]}"; do [[ -f "$f" ]] && cp "$f" "$current_bak/" 2>/dev/null; done

    # 2. Paketlisten
    rpm -qa --queryformat "%{NAME}\n" > "$current_bak/installed-packages.txt"
    flatpak list --app --columns=application > "$current_bak/flatpak-apps.txt" 2>/dev/null

    # 3. Firewall-Regeln
    sudo firewall-cmd --list-all > "$current_bak/firewall-rules.txt" 2>/dev/null
    mkdir -p "$current_bak/firewalld-zones"
    sudo cp /etc/firewalld/zones/* "$current_bak/firewalld-zones/" 2>/dev/null

    # 4. Netzwerkverbindungen (WLAN-Passwörter, VPNs)
    mkdir -p "$current_bak/network-connections"
    sudo cp -r /etc/NetworkManager/system-connections/* "$current_bak/network-connections/" 2>/dev/null

    # 5. SSH-Konfiguration
    cp /etc/ssh/sshd_config "$current_bak/" 2>/dev/null
    [[ -f "$user_home/.ssh/config" ]] && cp "$user_home/.ssh/config" "$current_bak/" 2>/dev/null

    # 6. SELinux-Konfiguration
    cp /etc/selinux/config "$current_bak/" 2>/dev/null

    # 7. CRON-Jobs
    crontab -l > "$current_bak/crontab-user.txt" 2>/dev/null
    sudo crontab -l > "$current_bak/crontab-root.txt" 2>/dev/null

    # 8. KDE Plasma-Einstellungen (Desktop-Spezifisch)
    mkdir -p "$current_bak/plasma-configs"
    cp "$user_home/.config/kdeglobals" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/plasmashellrc" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/kwinrc" "$current_bak/plasma-configs/" 2>/dev/null
    cp "$user_home/.config/kactivitymanagerdrc" "$current_bak/plasma-configs/" 2>/dev/null

    # Alte Backups aufräumen (max. 5)
    local count=$(ls -1d "$base_dir"/backup_* 2>/dev/null | wc -l)
    [[ $count -gt 5 ]] && ls -1dt "$base_dir"/backup_* | tail -n +6 | xargs rm -rf

    success "Backup erstellt in $current_bak"
}

# --- SMART ---
wait_for_smart() {
    local dev=$1; local type=$2
    ( while true; do sleep 45; if ! sudo smartctl -a "$dev" | grep -q "Self-test routine in progress"; then send_notify "SMART $type Test beendet!"; break; fi; done ) & disown
}

smart_disk_check() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   SMART Hardware Check ${NC}"
    sep
    echo -e "${YELLOW} Gesundheitszustand der Laufwerke prüfen.${NC}"
    sep
    info "Suche Hardware..."
    mapfile -t RAW_DISKS < <(sudo smartctl --scan-open | awk '{print $1}')
    [[ ${#RAW_DISKS[@]} -eq 0 ]] && mapfile -t RAW_DISKS < <(lsblk -dn -o NAME | awk '{print "/dev/"$1}')
    local DISK_LABELS=()
    for dev in "${RAW_DISKS[@]}"; do
        local model=$(sudo smartctl -i "$dev" | grep -E "Device Model|Model Number|User Capacity" | head -n 1 | cut -d: -f2 | sed 's/^[ \t]*//')
        DISK_LABELS+=("$dev | ${model:-Unbekannt}")
    done
    for i in "${!DISK_LABELS[@]}"; do printf "${CYAN} %d)${NC} %s\n" "$((i+1))" "${DISK_LABELS[i]}"; done
    sep
    read -rp "Wahl (0 für Zurück): " sel
    if [[ "$sel" -gt 0 && "$sel" -le "${#DISK_LABELS[@]}" ]]; then
        DEV=$(echo "${DISK_LABELS[sel-1]}" | cut -d'|' -f1 | xargs)
        MODEL=$(echo "${DISK_LABELS[sel-1]}" | cut -d'|' -f2 | xargs)
        while true; do
            clear
            sep
            echo -e "${WHITE}${BOLD}   SMART Menü: $DEV ${NC}"
            echo -e "${YELLOW}   Modell: $MODEL ${NC}"
            sep
            echo -e "${YELLOW}Führt Diagnosetests durch und liest Sensordaten aus.${NC}"
            sep
            echo -e "${CYAN} 1)${NC} Health Status (Schnell-Check)"
            echo -e "${CYAN} 2)${NC} Alle SMART-Attribute (Details)"
            echo -e "${CYAN} 3)${NC} Short Self-Test (ca. 2 Min)"
            echo -e "${CYAN} 4)${NC} Long Self-Test (Vollständig)"
            echo -e "${CYAN} 5)${NC} Test-Ergebnisse anzeigen"
            sep
            echo -e "${CYAN} 0)${NC} Zurück zur Auswahl"
            sep
            read -p "> " schoice
            case "$schoice" in
                1) sudo smartctl -H "$DEV" | sed -e "s/PASSED/${ESC}[1;32mPASSED${ESC}[0m/g" -e "s/FAILED/${ESC}[1;31mFAILED${ESC}[0m/g"; pause ;;
                2) sudo smartctl -A "$DEV" | show_with_pager; pause ;;
                3) sudo smartctl -t short "$DEV"; wait_for_smart "$DEV" "Short"; pause ;;
                              4)
                    echo -e "${YELLOW}Ein langer Selbsttest kann mehrere Stunden dauern${NC}"
                    echo -e "${YELLOW}und die Festplatte stark belasten. Der Test läuft im Hintergrund.${NC}"
                    read -rp "Long Self-Test starten? (y/N): " long_confirm
                    if [[ "$long_confirm" =~ ^[Yy]$ ]]; then
                        sudo smartctl -t long "$DEV"
                        wait_for_smart "$DEV" "Long"
                    else
                        warn "Abgebrochen."
                    fi
                    pause ;;
                5) sudo smartctl -l selftest "$DEV" | show_with_pager; pause ;;
                0) break ;;
            esac
        done
    fi
}

# --- STANDARD-KERNEL FESTLEGEN ---
set_default_kernel() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   Standard-Kernel festlegen ${NC}"
    sep
    echo -e "${YELLOW}Wählt den Kernel aus, der standardmäßig gebootet wird.${NC}"
    echo -e "${YELLOW}Dieser bleibt auch nach Kernel-Updates erhalten (solange er installiert ist).${NC}"
    sep

    # Liste aller vmlinuz-* Dateien in /boot (ausgenommen rescue)
    mapfile -t kernels < <(find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*-rescue-*' | sort -V)

    if [ ${#kernels[@]} -eq 0 ]; then
        error "Keine Kernel-Dateien in /boot gefunden."
        pause
        return
    fi

    # Anzeige mit Nummern
    local idx=1
    for kernel in "${kernels[@]}"; do
        version=$(basename "$kernel" | sed 's/^vmlinuz-//')
        echo -e "${CYAN} $idx)${NC} $version"
        ((idx++))
    done
    sep
    echo -e "${YELLOW}Wähle den Kernel, der als Standard gesetzt werden soll.${NC}"
    read -rp "Nummer (Enter = Abbruch): " choice

    if [[ -z "$choice" ]]; then
        warn "Abbruch."
        pause
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#kernels[@]} ]; then
        selected="${kernels[$((choice-1))]}"
        version=$(basename "$selected" | sed 's/^vmlinuz-//')

        echo -e "${YELLOW}Setze $version als Standard-Kernel...${NC}"
        if sudo grubby --set-default "$selected"; then
            success "Standard-Kernel auf $version gesetzt."
            echo -e "${YELLOW}Die Änderung wird beim nächsten Neustart wirksam.${NC}"
        else
            error "Fehler beim Setzen des Standards. Prüfe, ob 'grubby' installiert ist."
        fi
    else
        error "Ungültige Auswahl."
    fi
    pause
}

# --- KERNEL-MENÜ ---
kernel_menu() {
    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Kernel-Verwaltung ${NC}"
        sep
        echo -e "${YELLOW} Kernel installieren oder verwalten.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} CachyOS Kernel installieren"
        echo -e "${CYAN} 2)${NC} Nicht benötigte Kernel entfernen"
        echo -e "${CYAN} 3)${NC} Standard-Kernel festlegen (dauerhaft für GRUB)"
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
        sep
        read -p "> " kchoice
        case "$kchoice" in
            1) install_cachyos_kernel ;;
            2) remove_old_kernels ;;
            3) set_default_kernel ;;
            0) break ;;
            *) error "Ungültige Auswahl."; pause ;;
        esac
    done
}

# --- ALTE KERNEL ENTFERNEN (korrigiert) ---
remove_old_kernels() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   Nicht benötigte Kernel entfernen ${NC}"
    sep
    echo -e "${YELLOW} Warnung: Entferne nur Kernel, die du wirklich nicht${NC}"
    echo -e "${YELLOW} mehr brauchst.Behalte mindestens einen älteren Kernel${NC}"
    echo -e "${YELLOW} als Fallback, falls der aktuelle nicht bootet.${NC}"
    echo -e "${YELLOW} Ohne Fallback kann das System unbrauchbar werden!${NC}"
    sep

    # Aktuellen Kernel ermitteln (ohne Architektur, z.B. 6.19.9-200.fc43)
    local current_kernel_full=$(uname -r)
    local current_kernel="${current_kernel_full%.*}"  # Entfernt .x86_64 oder ähnliches
    echo -e "${GREEN}Aktuell laufender Kernel: ${WHITE}${BOLD}$current_kernel_full${NC}"
    sep

    # Alle installierten Kernel-Versionen sammeln (ohne Architektur)
    local kernel_versions=()
    while read -r pkg; do
        # Extrahiere Version aus Paketen wie kernel-core-6.19.8-200.fc43.x86_64
        if [[ "$pkg" =~ ^(kernel-core|kernel|kernel-cachyos-core)-([0-9].+)\.(x86_64|noarch) ]]; then
            version="${BASH_REMATCH[2]}"
            # Duplikate vermeiden
            if [[ ! " ${kernel_versions[@]} " =~ " ${version} " ]]; then
                kernel_versions+=("$version")
            fi
        fi
    done < <(rpm -qa | grep -E "^(kernel-core|kernel|kernel-cachyos-core)-[0-9]")

    if [ ${#kernel_versions[@]} -eq 0 ]; then
        echo -e "${YELLOW}Keine weiteren Kernel gefunden.${NC}"
        pause
        return
    fi

    # Liste der auswählbaren Kernel (alle außer aktuellem)
    local selectable=()
    local selectable_versions=()
    local idx=1
    echo -e "${CYAN}Verfügbare Kernel (außer aktuell):${NC}"
    for ver in "${kernel_versions[@]}"; do
        # Vergleiche ohne Architektur
        if [[ "$ver" != "$current_kernel" ]]; then
            echo -e " ${CYAN}$idx)${NC} $ver"
            selectable+=("$ver")
            selectable_versions+=("$ver")
            ((idx++))
        fi
    done

    if [ ${#selectable[@]} -eq 0 ]; then
        echo -e "${GREEN}Keine alten Kernel gefunden. Alles sauber.${NC}"
        pause
        return
    fi

    sep
    echo -e "${YELLOW}Wähle die Nummer(n) des/der zu entfernenden Kernel(s).${NC}"
    echo -e "${YELLOW}Mehrere durch Leerzeichen getrennt. Enter = Abbruch.${NC}"
    read -rp "> " choices

    if [[ -z "$choices" ]]; then
        warn "Abbruch."
        pause
        return
    fi

    # Auswahl parsen und Pakete sammeln
    local to_remove_pkgs=()
    for choice in $choices; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#selectable[@]} ]; then
            local ver="${selectable[$choice-1]}"
            # Finde alle Pakete, die zu dieser Version gehören
            mapfile -t pkgs < <(rpm -qa | grep -E "(^kernel-core-${ver}|^kernel-${ver}|^kernel-modules-${ver}|^kernel-devel-${ver}|^kernel-cachyos-core-${ver}|^kernel-cachyos-${ver}|^kernel-cachyos-modules-${ver}|^kernel-cachyos-devel-${ver})" | sort -u)
            for p in "${pkgs[@]}"; do
                to_remove_pkgs+=("$p")
            done
        else
            warn "Ungültige Auswahl: $choice"
        fi
    done

    if [ ${#to_remove_pkgs[@]} -eq 0 ]; then
        warn "Keine gültigen Kernel ausgewählt."
        pause
        return
    fi

    # Letzte Warnung anzeigen
    echo -e "${RED}${BOLD}ACHTUNG:${NC} Du entfernst folgende Kernel-Pakete:"
    for p in "${to_remove_pkgs[@]}"; do
        echo "  - $p"
    done
    echo -e "${YELLOW}Stelle sicher, dass mindestens ein funktionierender Kernel (außer dem aktuellen)${NC}"
    echo -e "${YELLOW}erhalten bleibt, falls der aktuelle Kernel Probleme macht.${NC}"
    read -rp "Wirklich entfernen? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo dnf remove -y "${to_remove_pkgs[@]}"
        success "Kernel entfernt."
        echo -e "${YELLOW}Hinweis: GRUB-Konfiguration wurde automatisch aktualisiert.${NC}"
    else
        warn "Abgebrochen."
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
        echo -e "${YELLOW} Verwalte Systemd-Dienste (Anzeige, Start, Stop, etc.)${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Alle Dienste anzeigen"
        echo -e "${CYAN} 2)${NC} Laufende Dienste anzeigen"
        echo -e "${CYAN} 3)${NC} Fehlgeschlagene Dienste anzeigen"
        echo -e "${CYAN} 4)${NC} Aktivierte Autostart-Dienste anzeigen"
        echo -e "${CYAN} 5)${NC} Service auswählen für Aktionen"
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
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
                echo -e "${YELLOW}Gib den genauen Service-Namen ein (z.B. sshd, NetworkManager, httpd):${NC}"
                read -rp "> " service_name
                if [[ -z "$service_name" ]]; then
                    warn "Kein Name eingegeben."
                    pause
                    continue
                fi
                # .service automatisch anhängen, falls fehlt
                if [[ "$service_name" != *".service" ]]; then
                    service_name="${service_name}.service"
                fi
                # Prüfen, ob Service existiert (mit systemctl cat)
                if ! systemctl cat "$service_name" &>/dev/null; then
                    error "Service $service_name nicht gefunden."
                    pause
                    continue
                fi
                # Untermenü für Aktionen
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Service: $service_name ${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Status anzeigen"
                    echo -e "${CYAN} 2)${NC} Logs anzeigen (letzte 20 Zeilen)"
                    echo -e "${CYAN} 3)${NC} Starten"
                    echo -e "${CYAN} 4)${NC} Stoppen"
                    echo -e "${CYAN} 5)${NC} Neustarten"
                    echo -e "${CYAN} 6)${NC} Aktivieren (Autostart beim Boot)"
                    echo -e "${CYAN} 7)${NC} Deaktivieren (Autostart entfernen)"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück zur Service-Auswahl"
                    sep
                    read -p "> " action
                                    case "$action" in
                        1)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Status von $service_name ${NC}"
                            sep
                            SYSTEMD_COLORS=1 systemctl status "$service_name" --no-pager
                            sep
                            pause
                            ;;
                        2)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Logs von $service_name (letzte 20 Zeilen) ${NC}"
                            sep
                            sudo journalctl -u "$service_name" -n 20 --no-pager
                            sep
                            pause
                            ;;
                        3)
                            echo -e "${YELLOW}Starte $service_name ...${NC}"
                            sudo systemctl start "$service_name"
                            if [ $? -eq 0 ]; then
                                success "$service_name gestartet."
                            else
                                error "Start fehlgeschlagen."
                            fi
                            pause
                            ;;
                        4)
                            read -rp "Service $service_name wirklich stoppen? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl stop "$service_name"
                                success "$service_name gestoppt."
                            else
                                warn "Abgebrochen."
                            fi
                            pause
                            ;;
                        5)
                            read -rp "Service $service_name wirklich neustarten? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl restart "$service_name"
                                success "$service_name neugestartet."
                            else
                                warn "Abgebrochen."
                            fi
                            pause
                            ;;
                        6)
                            sudo systemctl enable "$service_name"
                            success "$service_name aktiviert (Autostart)."
                            pause
                            ;;
                        7)
                            read -rp "Autostart für $service_name wirklich deaktivieren? (y/N): " confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                sudo systemctl disable "$service_name"
                                success "$service_name deaktiviert."
                            else
                                warn "Abgebrochen."
                            fi
                            pause
                            ;;
                        0)
                            break
                            ;;
                        *)
                            error "Ungültige Auswahl."
                            pause
                            ;;
                    esac
                done
                ;;
            0) break ;;
            *) error "Ungültige Auswahl."; pause ;;
        esac
        done
        }

        # --- FLATPAK-VERWALTUNG ---
flatpak_management() {
    # Prüfen, ob flatpak installiert ist
    if ! command -v flatpak >/dev/null 2>&1; then
        error "Flatpak ist nicht installiert."
        pause
        return
    fi

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Flatpak-Verwaltung ${NC}"
        sep
        echo -e "${YELLOW} Verwalte Flatpak-Anwendungen (Update,Repair,Remove).${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Flatpaks Update & Repair"
        echo -e "${CYAN} 2)${NC} Installierte Flatpaks anzeigen (Liste)"
        echo -e "${CYAN} 3)${NC} Details zu einer Flatpak-Anwendung anzeigen"
        echo -e "${CYAN} 4)${NC} Flatpak neu installieren (reinstall)"
        echo -e "${CYAN} 5)${NC} Flatpak entfernen"
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
        sep
        read -p "> " fp_choice
        case "$fp_choice" in
            1)  info "Flatpak Wartung..."
                sudo flatpak update -y && sudo flatpak repair && sudo flatpak uninstall --unused -y; success "Fertig."; pause ;;
            2)
                clear
                sep
                echo -e "${WHITE}${BOLD}   Installierte Flatpaks ${NC}"
                sep
                flatpak list --app --columns=application | show_with_pager
                pause
                ;;
            3)
                echo -e "${YELLOW}Gib den genauen Anwendungsnamen ein (z.B. org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "Kein Name eingegeben."
                    pause
                    continue
                fi
                # Prüfen, ob installiert
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name nicht gefunden oder nicht installiert."
                    pause
                    continue
                fi
                clear
                sep
                echo -e "${WHITE}${BOLD}   Details zu $app_name ${NC}"
                sep
                flatpak info "$app_name" | show_with_pager
                pause
                ;;
            4)
                echo -e "${YELLOW}Gib den genauen Anwendungsnamen ein (z.B. org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "Kein Name eingegeben."
                    pause
                    continue
                fi
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name nicht gefunden oder nicht installiert."
                    pause
                    continue
                fi
                echo -e "${YELLOW}Flatpak $app_name neu installieren? (y/N):${NC}"
                read -rp "> " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    sudo flatpak uninstall -y "$app_name" && sudo flatpak install -y "$app_name"
                    if [ $? -eq 0 ]; then
                        success "$app_name neu installiert."
                    else
                        error "Neuinstallation fehlgeschlagen."
                    fi
                else
                    warn "Abgebrochen."
                fi
                pause
                ;;
            5)
                echo -e "${YELLOW}Gib den genauen Anwendungsnamen ein (z.B. org.mozilla.firefox):${NC}"
                read -rp "> " app_name
                if [[ -z "$app_name" ]]; then
                    warn "Kein Name eingegeben."
                    pause
                    continue
                fi
                if ! flatpak info "$app_name" &>/dev/null; then
                    error "Flatpak $app_name nicht gefunden oder nicht installiert."
                    pause
                    continue
                fi
                echo -e "${RED}${BOLD}ACHTUNG: Entfernen von $app_name${NC}"
                echo -e "${YELLOW}Dies löscht die Anwendung und alle zugehörigen Daten.${NC}"
                read -rp "Wirklich entfernen? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    sudo flatpak uninstall -y "$app_name"
                    if [ $? -eq 0 ]; then
                        success "$app_name entfernt."
                    else
                        error "Entfernen fehlgeschlagen."
                    fi
                else
                    warn "Abgebrochen."
                fi
                pause
                ;;
            0) break ;;
            *) error "Ungültige Auswahl."; pause ;;
        esac
    done
}

    # --- CACHYOS KERNEL INSTALLATION (korrigierte CPU-Prüfung) ---
    install_cachyos_kernel() {
    clear
    sep
    echo -e "${WHITE}${BOLD}   CachyOS Kernel Installation ${NC}"
    sep
    echo -e "${YELLOW}Dieser Kernel ist für moderne CPUs mit x86_64_v3 optimiert.${NC}"
    sep

    # Bestätigung vor der Installation
    echo -e "${YELLOW}Die Installation eines alternativen Kernels kann das System instabil machen.${NC}"
    echo -e "${YELLOW}Stelle sicher, dass ein aktuelles Backup vorhanden ist.${NC}"
    read -rp "Fortfahren? (y/N): " kernel_confirm
    if [[ ! "$kernel_confirm" =~ ^[Yy]$ ]]; then
        warn "Abgebrochen."
        pause
        return
    fi

    # 1. CPU-Unterstützung prüfen (robust)
    info "Prüfe CPU-Unterstützung für x86_64_v3..."
    local supported=false

    # Methode 1: gcc -march (falls vorhanden)
    if command -v gcc >/dev/null 2>&1; then
        if gcc -march=x86-64-v3 -dM -E - < /dev/null > /dev/null 2>&1; then
            supported=true
        fi
    fi

    # Methode 2: Falls gcc nicht vorhanden, CPU-Flags aus /proc/cpuinfo auswerten
    if [[ "$supported" == false ]]; then
        if grep -q -E '^flags\s*:.*\b(avx2|bmi1|bmi2|fma)\b' /proc/cpuinfo; then
            # Mindestens die wichtigsten v3-Flags vorhanden
            supported=true
        fi
    fi

    if [[ "$supported" == true ]]; then
        success "x86_64_v3 wird unterstützt. Installation kann fortgesetzt werden."
    else
        error "Deine CPU unterstützt nicht x86_64_v3. Der CachyOS-Kernel ist nicht geeignet."
        warn "Verwende stattdessen den regulären Fedora-Kernel oder den LTS-Kernel."
        pause
        return 1
    fi

    # 2. SELinux-Policy setzen falls aktiv
    if [[ $(getenforce) != "Disabled" ]]; then
        info "SELinux ist aktiv. Setze benötigte Policy..."
        if sudo setsebool -P domain_kernel_load_modules on; then
            success "SELinux-Policy 'domain_kernel_load_modules' gesetzt."
        else
            error "Konnte SELinux-Policy nicht setzen. Abbruch."
            pause
            return 1
        fi
    else
        info "SELinux ist deaktiviert – keine zusätzliche Policy nötig."
    fi

    # 3. COPR Repos hinzufügen
    info "Füge CachyOS COPR Repositories hinzu..."
    if sudo dnf copr enable bieszczaders/kernel-cachyos -y && \
       sudo dnf copr enable bieszczaders/kernel-cachyos-addons -y; then
        success "COPR Repos erfolgreich hinzugefügt."
    else
        error "Fehler beim Hinzufügen der COPR Repos. Abbruch."
        pause
        return 1
    fi

    # 4. Kernel installieren
    info "Installiere CachyOS-Kernel und Entwicklerpakete..."
    sudo dnf install -y kernel-cachyos kernel-cachyos-devel

    success "Installation abgeschlossen. Ein Neustart ist erforderlich, um den neuen Kernel zu laden."
    pause
}

# --- WIEDERHERSTELLUNG AUS BACKUP ---
restore_menu() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups"

    # Prüfen, ob Backups existieren
    mapfile -t backups < <(ls -1dt "$base_dir"/backup_* 2>/dev/null)
    if [ ${#backups[@]} -eq 0 ]; then
        error "Keine Backups im Ordner $base_dir gefunden."
        pause
        return
    fi

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Wiederherstellung aus Backup ${NC}"
        sep
        echo -e "${YELLOW}Wähle ein Backup, zum wiederhergestellen.${NC}"
        sep

        local idx=1
        for backup in "${backups[@]}"; do
            echo -e "${CYAN} $idx)${NC} $(basename "$backup")"
            ((idx++))
        done
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
        sep
        read -rp "> " backup_choice

        if [[ "$backup_choice" -eq 0 ]]; then
            break
        elif [[ "$backup_choice" -ge 1 && "$backup_choice" -le ${#backups[@]} ]]; then
            local selected_backup="${backups[$((backup_choice-1))]}"
            restore_submenu "$selected_backup"
        else
            error "Ungültige Auswahl."
            pause
        fi
    done
}

# --- DESKTOP-EINSTELLUNGEN (Plasma, Dolphin, KWin) ---
desktop_settings_menu() {
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local base_dir="$user_home/System_Backups/desktop-settings"

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Desktop-Einstellungen sichern/wiederherstellen ${NC}"
        sep
        echo -e "${YELLOW} Plasma, Dolphin, KWin – nur ausgewählte Konfigdateien${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Desktop-Einstellungen sichern"
        echo -e "${CYAN} 2)${NC} Desktop-Einstellungen wiederherstellen"
        sep
        echo -e "${CYAN} 0)${NC} Zurück"
        sep
        read -rp "> " dchoice
        case "$dchoice" in
            1) save_desktop_settings "$base_dir" ;;
            2) restore_desktop_settings "$base_dir" ;;
            0) break ;;
            *) error "Ungültige Auswahl."; pause ;;
        esac
    done
}

save_desktop_settings() {
    local base_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local target_dir="$base_dir/backup_$timestamp"

    mkdir -p "$target_dir"

    # Liste der gewünschten Dateien (relativ zu ~/.config)
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
            echo -e "${GREEN}  → $(basename "$file") gesichert${NC}"
            any_copied=true
        else
            echo -e "${YELLOW}  → $(basename "$file") nicht gefunden (übersprungen)${NC}"
        fi
    done

    if $any_copied; then
        # Alte Backups aufräumen (max. 5)
        local count=$(ls -1d "$base_dir"/backup_* 2>/dev/null | wc -l)
        if [[ $count -gt 5 ]]; then
            ls -1dt "$base_dir"/backup_* | tail -n +6 | xargs rm -rf
            echo -e "${YELLOW}Alte Backups (max. 5) aufgeräumt.${NC}"
        fi
        success "Desktop-Einstellungen gesichert in: $target_dir"
    else
        error "Keine der Konfigurationsdateien gefunden – nichts gesichert."
        rmdir "$target_dir" 2>/dev/null
    fi
    pause
}

restore_desktop_settings() {
    local base_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")

    # Prüfen, ob Backups existieren
    mapfile -t backups < <(ls -1dt "$base_dir"/backup_* 2>/dev/null)
    if [ ${#backups[@]} -eq 0 ]; then
        error "Keine Desktop-Backups gefunden (Verzeichnis: $base_dir)."
        pause
        return
    fi

    # Backup auswählen
    clear
    sep
    echo -e "${WHITE}${BOLD}   Desktop-Einstellungen wiederherstellen ${NC}"
    sep
    echo -e "${YELLOW}Wähle ein Backup aus:${NC}"
    local idx=1
    for backup in "${backups[@]}"; do
        echo -e "${CYAN} $idx)${NC} $(basename "$backup")"
        ((idx++))
    done
    sep
    echo -e "${CYAN} 0)${NC} Abbrechen"
    sep
    read -rp "> " choice

    if [[ "$choice" -eq 0 ]]; then
        return
    elif [[ "$choice" -ge 1 && "$choice" -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((choice-1))]}"

        echo -e "${YELLOW}Folgende Dateien werden wiederhergestellt:${NC}"
        ls -1 "$selected_backup" | sed 's/^/  - /'
        echo -e "${YELLOW}Vorhandene Originaldateien werden vorher gesichert (mit .old).${NC}"
        read -rp "Wiederherstellung durchführen? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            local any_restored=false
            for file in "$selected_backup"/*; do
                filename=$(basename "$file")
                target="$user_home/.config/$filename"
                # Sicherung der existierenden Datei
                if [ -f "$target" ]; then
                    cp "$target" "$target.old"
                    echo -e "${CYAN}  → Sicherung von $filename als .old${NC}"
                fi
                cp "$file" "$target"
                echo -e "${GREEN}  → $filename wiederhergestellt${NC}"
                any_restored=true
            done

            if $any_restored; then
                success "Desktop-Einstellungen wiederhergestellt."
                echo -e "${YELLOW}Hinweis: Einige Änderungen werden erst nach einem Neustart von Plasma wirksam.${NC}"
                echo -e "${YELLOW}Du kannst 'kwin_x11 --replace &' oder 'plasmashell --replace &' ausführen.${NC}"
            fi
        else
            warn "Abgebrochen."
        fi
    else
        error "Ungültige Auswahl."
    fi
    pause
}

# --- Untermenü für ein konkretes Backup ---
restore_submenu() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")

    while true; do
        clear
        sep
        echo -e "${WHITE}${BOLD}   Wiederherstellung aus: $(basename "$backup_dir") ${NC}"
        sep
        echo -e "${YELLOW}Wähle die wiederherzustellenden Daten.${NC}"
        echo -e "${YELLOW}Vorhandene Dateien im Ziel werden bei Bedarf überschrieben.${NC}"
        sep
        echo -e "${CYAN} 1)${NC} Systemkonfigurationen (fstab, dnf.conf, hosts, hostname, grub, bashrc, maint)"
        echo -e "${CYAN} 2)${NC} Paketliste wiederherstellen (alle DNF Anwendungen)"
        echo -e "${CYAN} 3)${NC} Firewall & Netzwerk (Firewall-Regeln, Netzwerkverbindungen)"
        echo -e "${CYAN} 4)${NC} Plasma-Einstellungen (Desktop-Konfiguration)"
        echo -e "${CYAN} 5)${NC} Cron-Jobs (Benutzer und Root)"
        echo -e "${CYAN} 6)${NC} ALLE (alle oben genannten Kategorien)"
        sep
        echo -e "${CYAN} 0)${NC} Zurück zur Backup-Auswahl"
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
                success "Alle ausgewählten Kategorien wurden wiederhergestellt."
                pause
                ;;
            0) break ;;
            *) error "Ungültige Auswahl."; pause ;;
        esac
    done
}

# --- Hilfsfunktionen für die Wiederherstellung ---
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

    echo -e "${YELLOW}Wiederherstellung von Systemkonfigurationen...${NC}"
    local any_restored=false
    for entry in "${targets[@]}"; do
        target="${entry%:*}"
        source="${entry#*:}"
        if [ -f "$source" ]; then
            echo -e "${CYAN}Datei $target wird ersetzt?${NC}"
            read -rp "Wiederherstellen? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # Backup der bestehenden Datei erstellen, falls sie existiert
                if [ -f "$target" ]; then
                    sudo cp "$target" "$target.restore-backup" 2>/dev/null
                fi
                sudo cp "$source" "$target" 2>/dev/null
                echo -e "${GREEN}  -> $target wiederhergestellt${NC}"
                any_restored=true
            fi
        fi
    done

    if $any_restored && [[ -f "$backup_dir/grub" ]]; then
        echo -e "${YELLOW}GRUB-Konfiguration wurde geändert. GRUB neu generieren? (y/N):${NC}"
        read -rp "> " gen_grub
        if [[ "$gen_grub" =~ ^[Yy]$ ]]; then
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            success "GRUB-Konfiguration aktualisiert."
        fi
    fi
    if ! $any_restored; then
        echo -e "${YELLOW}Keine Systemkonfigurationen wiederhergestellt.${NC}"
    fi
    pause
}

restore_packages() {
    local backup_dir="$1"
    local pkg_file="$backup_dir/installed-packages.txt"

    if [ ! -f "$pkg_file" ]; then
        warn "Keine Paketliste im Backup gefunden."
        pause
        return
    fi

    echo -e "${YELLOW}Es werden alle Pakete aus der Liste installiert.${NC}"
    echo -e "${YELLOW}Das kann sehr lange dauern und evtl. zu Konflikten führen,${NC}"
    echo -e "${YELLOW}da zwischenzeitlich neue Paketversionen erschienen sein können.${NC}"
    echo -e "${YELLOW}Empfehlung: Vorher ein aktuelles Backup machen!${NC}"
    sep
    echo -e "${CYAN}Erste 20 Pakete als Vorschau:${NC}"
    head -n 20 "$pkg_file" | cat -n
    if [ $(wc -l < "$pkg_file") -gt 20 ]; then
        echo -e "${YELLOW}... und $(($(wc -l < "$pkg_file") - 20)) weitere.${NC}"
    fi
    sep
    read -rp "Möchtest du die Paketliste wirklich installieren? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Starte Installation der Pakete (dies kann einige Zeit dauern)..."
        # Option: --skip-broken, um bei fehlenden Paketen weiterzumachen
        sudo dnf install -y --skip-broken $(cat "$pkg_file")
        if [ $? -eq 0 ]; then
            success "Alle Pakete wurden erfolgreich installiert."
        else
            error "Es traten Fehler bei der Installation auf. Prüfe die Ausgabe."
        fi
    else
        warn "Installation abgebrochen."
    fi
    pause
}

restore_network_firewall() {
    local backup_dir="$1"
    local any_restored=false

    # Firewall-Regeln (nur anzeigen)
    if [ -f "$backup_dir/firewall-rules.txt" ]; then
        echo -e "${YELLOW}Firewall-Regeln (nur zur Ansicht):${NC}"
        cat "$backup_dir/firewall-rules.txt" | show_with_pager
    fi

    # Firewall-Zonen
    if [ -d "$backup_dir/firewalld-zones" ] && [ -n "$(ls -A "$backup_dir/firewalld-zones" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Firewall-Zonen wiederherstellen? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo cp -r "$backup_dir/firewalld-zones"/* /etc/firewalld/zones/ 2>/dev/null
            sudo firewall-cmd --reload
            success "Firewall-Zonen wiederhergestellt."
            any_restored=true
        fi
    fi

    # Netzwerkverbindungen
    if [ -d "$backup_dir/network-connections" ] && [ -n "$(ls -A "$backup_dir/network-connections" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Netzwerkverbindungen wiederherstellen? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo cp -r "$backup_dir/network-connections"/* /etc/NetworkManager/system-connections/ 2>/dev/null
            sudo systemctl restart NetworkManager
            success "Netzwerkverbindungen wiederhergestellt."
            any_restored=true
        fi
    fi

    if ! $any_restored; then
        echo -e "${YELLOW}Keine Netzwerk-/Firewall-Konfigurationen wiederhergestellt.${NC}"
    fi
    pause
}

restore_plasma_configs() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local plasma_dir="$backup_dir/plasma-configs"

    if [ -d "$plasma_dir" ] && [ -n "$(ls -A "$plasma_dir" 2>/dev/null)" ]; then
        echo -e "${YELLOW}Plasma-Einstellungen wiederherstellen? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Bestehende Konfiguration sichern
            mkdir -p "$user_home/.config/restore-backup"
            cp "$user_home/.config/kdeglobals" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/plasmashellrc" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/kwinrc" "$user_home/.config/restore-backup/" 2>/dev/null
            cp "$user_home/.config/kactivitymanagerdrc" "$user_home/.config/restore-backup/" 2>/dev/null

            cp "$plasma_dir"/* "$user_home/.config/" 2>/dev/null
            success "Plasma-Einstellungen wiederhergestellt."
            echo -e "${YELLOW}Hinweis: Einige Änderungen werden erst nach einem Neustart der Plasma-Session wirksam.${NC}"
        else
            echo -e "${YELLOW}Übersprungen.${NC}"
        fi
    else
        warn "Keine Plasma-Einstellungen im Backup gefunden."
    fi
    pause
}

restore_cron_jobs() {
    local backup_dir="$1"
    local user_home=$(eval echo "~${SUDO_USER:-$USER}")
    local any_restored=false

    # Benutzer-Crontab
    if [ -f "$backup_dir/crontab-user.txt" ]; then
        echo -e "${YELLOW}Benutzer-Crontab wiederherstellen? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            crontab -l 2>/dev/null > "$user_home/crontab.backup"  # altes sichern
            crontab "$backup_dir/crontab-user.txt"
            success "Benutzer-Crontab wiederhergestellt."
            any_restored=true
        fi
    fi

    # Root-Crontab
    if [ -f "$backup_dir/crontab-root.txt" ]; then
        echo -e "${YELLOW}Root-Crontab wiederherstellen? (y/N):${NC}"
        read -rp "> " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo crontab -l > /tmp/rootcrontab.backup 2>/dev/null
            sudo crontab "$backup_dir/crontab-root.txt"
            success "Root-Crontab wiederhergestellt."
            any_restored=true
        fi
    fi

    if ! $any_restored; then
        echo -e "${YELLOW}Keine Cron-Jobs wiederhergestellt.${NC}"
    fi
    pause
}

# --- HAUPTMENÜ ---
main_menu() {
    check_deps
    while true; do
                clear
        sep
        echo -e "${RED}${BOLD} ⚠️ WARNUNG: Dieses Skript führt Systemänderungen${NC}"
        echo -e "${RED}${BOLD} ⚠️ OHNE weitere Passwortabfrage durch!${NC}"
        sep
        echo -e "${WHITE}${BOLD}    >>>>>> FEDORA 43 MAINTENANCE PRO v10.14.0 <<<<<<${NC}"
        sep

        echo -e "${WHITE}${BOLD}    [WARTUNG & UPDATES]${NC}"
        echo -e "${YELLOW} A) [AUTOPILOT]  Wartung + Backup${NC}"
        echo -e "${YELLOW} B) [BACKUP]     Konfigurationen sichern (max. 5)${NC}"
        echo -e "${YELLOW} C) [RESTORE]    Wiederherstellung aus Backup${NC}"
        echo -e "${CYAN} 1)${NC} System Update (DNF)"
        echo -e "${CYAN} 2)${NC} Flatpak (Update/Repair/Verwaltung)"
        echo -e "${CYAN} 3)${NC} Firmware-Updates (fwupd)"
        echo -e "${CYAN} 4)${NC} DNF (Aufräumen/Suche/Infos)"
        echo -e "${CYAN} 5)${NC} Journal & Logs (Vacuum/Rotate)"
        echo -e "${CYAN} 6)${NC} System-Caches verwalten"
        echo -e "${CYAN} 7)${NC} Vorinstallierte Apps (Bloatware) entfernen"
        sep

        echo -e "${WHITE}${BOLD}    [HARDWARE & DIAGNOSE]${NC}"
        echo -e "${CYAN} 8)${NC} SMART Hardware Check"
        echo -e "${CYAN} 9)${NC} SSD TRIM (Alle Partitionen)"
        echo -e "${CYAN}10)${NC} HDD Spindown (hd-idle) Steuerung"
        echo -e "${CYAN}11)${NC} Btrfs-Wartungsmenü"
        echo -e "${CYAN}12)${NC} System Health & Infos"
        echo -e "${CYAN}13)${NC} Boot-Zeit Analyse & Bootloader"
        echo -e "${CYAN}14)${NC} Stresstest & Monitoring"
        sep

        echo -e "${WHITE}${BOLD}    [WERKZEUGE & VERWALTUNG]${NC}"
        echo -e "${CYAN} D)${NC} Desktop-Einstellungen (Plasma, Dolphin, KWin)"
        echo -e "${CYAN} R)${NC} Paket-Reparatur (RPM/DNF)"
        echo -e "${CYAN} N)${NC} Netzwerk Werkzeuge"
        echo -e "${CYAN} L)${NC} Wartungs-Logs einsehen"
        echo -e "${CYAN} K)${NC} Kernel-Verwaltung"
        echo -e "${CYAN} S)${NC} Systemd Service Manager"
        sep

        echo -e "${CYAN} 0)${NC} Beenden"
        sep

        read -rp "> " choice
        case "${choice,,}" in
                       a)
                clear
                sep
                echo -e "${WHITE}${BOLD}   Autopilot Wartung ${NC}"
                sep
                echo -e "${YELLOW} Folgende Aktionen werden ausgeführt:${NC}"
                echo -e "  • Backup wichtiger Konfigurationen (max. 5 Versionen)"
                echo -e "  • DNF System-Update (alle Pakete)"
                echo -e "  • Flatpak Update & Repair & Unused entfernen"
                echo -e "  • Journal-Log auf 200MB begrenzen"
                echo -e "  • Logrotate ausführen"
                echo -e "  • SSD TRIM auf allen Laufwerken"
                echo -e "  • Desktop-Benachrichtigung am Ende"
                sep
                read -rp " Möchten Sie den Autopiloten starten? (y/N): " auto_confirm
                if [[ "$auto_confirm" =~ ^[Yy]$ ]]; then
                    config_backup
                    sudo dnf upgrade --refresh -y
                    sudo flatpak update -y
                    sudo flatpak repair
                    sudo flatpak uninstall --unused -y
                    sudo journalctl --vacuum-size=200M
                    sudo logrotate /etc/logrotate.conf
                    sudo fstrim -av
                    send_notify "Autopilot Wartung abgeschlossen."
                    success "Autopilot fertig."
                else
                    warn "Autopilot abgebrochen."
                fi
                pause ;;
            b) config_backup; pause ;;
            c) restore_menu ;;
            1) sudo dnf upgrade --refresh -y; pause ;;
            2) flatpak_management ;;
            3) clear; info "Suche nach Firmware-Updates..."; sudo fwupdmgr refresh && sudo fwupdmgr update; pause ;;
            4)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   DNF Aufräumen & Historie ${NC}"
                    sep
                    echo -e "${YELLOW} Verwaltet Paket-Transaktionen.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Autoremove     (Entf. nicht benöt. Abhängigkeiten)"
                    echo -e "${CYAN} 2)${NC} Clean All      (Leert gesamten DNF-Paket-Cache)"
                    echo -e "${CYAN} 3)${NC} History & Undo (erlaubt Rollbacks)"
                    echo -e "${CYAN} 4)${NC} Installierte Pakete durchsuchen (Paketname)"
                    echo -e "${CYAN} 5)${NC} Paketdetails & Aktionen (Remove, Reinstall etc.)"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück"
                    sep
                    read -p "> " dnf_choice
                    case "$dnf_choice" in
                        1) sudo dnf autoremove -y; success "Autoremove abgeschlossen."; pause ;;
                        2)
                            echo -e "${YELLOW}Dies leert den gesamten DNF-Paket-Cache.${NC}"
                            echo -e "${YELLOW}Danach müssen Pakete bei Bedarf neu heruntergeladen werden.${NC}"
                            read -rp "Wirklich DNF Clean All durchführen? (y/N): " clean_confirm
                            if [[ "$clean_confirm" =~ ^[Yy]$ ]]; then
                                sudo dnf clean all
                                success "DNF Cache geleert."
                            else
                                warn "Abgebrochen."
                            fi
                            pause ;;
                        3)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   DNF History & Undo ${NC}"
                            sep
                            sudo dnf history list | head -n 30
                            sep
                            echo -e "${YELLOW}Gib die ID der Transaktion ein, die du rückgängig machen möchtest.${NC}"
                            echo -e "${YELLOW}Leere Eingabe = zurück zum Menü.${NC}"
                            read -rp "ID: " tx
                            if [[ -n "$tx" ]]; then
                                clear
                                sep
                                echo -e "${WHITE}${BOLD}   Details zu Transaktion $tx ${NC}"
                                sep
                                sudo dnf history info "$tx"
                                sep
                                echo -e "${YELLOW}Möchtest du diese Transaktion wirklich rückgängig machen?${NC}"
                                echo -e "${YELLOW}Dies wird die Paketänderungen dieser Transaktion zurückdrehen.${NC}"
                                read -rp "Durchführen? (y/N): " confirm
                                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                    info "Führe Undo für Transaktion $tx durch..."
                                    sudo dnf history undo -y "$tx"
                                    if [ $? -eq 0 ]; then
                                        success "Undo erfolgreich abgeschlossen."
                                    else
                                        error "Undo fehlgeschlagen. Siehe Meldung oben."
                                    fi
                                else
                                    warn "Undo abgebrochen."
                                fi
                            fi
                            pause ;;
                        4)
                            echo -e "${YELLOW}Gib einen Suchbegriff ein (Paketname):${NC}"
                            read -rp "> " search_term
                            if [[ -z "$search_term" ]]; then
                                warn "Kein Suchbegriff eingegeben."
                                pause
                                continue
                            fi
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Suchergebnisse für: $search_term ${NC}"
                            sep
                            # Nur Paketnamen durchsuchen (mit rpm)
                            rpm -qa | grep -i "$search_term" | show_with_pager
                            if [ $? -ne 0 ]; then
                                echo -e "${YELLOW}Keine installierten Pakete mit '$search_term' im Namen gefunden.${NC}"
                            fi
                            pause
                            ;;
                        5)
                            echo -e "${YELLOW}Gib den exakten Paketnamen ein (z.B. firefox, kernel):${NC}"
                            read -rp "> " pkg_name
                            if [[ -z "$pkg_name" ]]; then
                                warn "Kein Name eingegeben."
                                pause
                                continue
                            fi
                            # Prüfen, ob Paket installiert ist
                            if ! rpm -q "$pkg_name" &>/dev/null; then
                                error "Paket $pkg_name ist nicht installiert."
                                pause
                                continue
                            fi
                            while true; do
                                clear
                                sep
                                echo -e "${WHITE}${BOLD}   Paket: $pkg_name ${NC}"
                                sep
                                echo -e "${CYAN} 1)${NC} Informationen anzeigen (dnf info)"
                                echo -e "${CYAN} 2)${NC} Abhängigkeiten anzeigen (benötigte Pakete)"
                                echo -e "${CYAN} 3)${NC} Abhängige Pakete anzeigen (die Paket benötigen)"
                                echo -e "${CYAN} 4)${NC} Neu installieren (reinstall)"
                                echo -e "${CYAN} 5)${NC} Entfernen (remove)"
                                sep
                                echo -e "${CYAN} 0)${NC} Zurück"
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
                                        echo -e "${WHITE}${BOLD}   Benötigte Abhängigkeiten von $pkg_name ${NC}"
                                        sep
                                        dnf repoquery --requires --installed "$pkg_name" | show_with_pager
                                        pause
                                        ;;
                                    3)
                                        clear
                                        sep
                                        echo -e "${WHITE}${BOLD}   Pakete, die $pkg_name benötigen ${NC}"
                                        sep
                                        dnf repoquery --whatrequires --installed "$pkg_name" | show_with_pager
                                        pause
                                        ;;
                                    4)
                                        echo -e "${YELLOW}Neuinstallation von $pkg_name durchführen? (y/N):${NC}"
                                        read -rp "> " reinstall_confirm
                                        if [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                                            sudo dnf reinstall -y "$pkg_name"
                                            success "$pkg_name neu installiert."
                                        else
                                            warn "Abgebrochen."
                                        fi
                                        pause
                                        ;;
                                    5)
                                        echo -e "${RED}${BOLD}ACHTUNG: Entfernen von $pkg_name${NC}"
                                        echo -e "${YELLOW}Dies kann das System destabilisieren, wenn es wichtige Abhängigkeiten sind.${NC}"
                                        read -rp "Wirklich entfernen? (y/N): " remove_confirm
                                        if [[ "$remove_confirm" =~ ^[Yy]$ ]]; then
                                            sudo dnf remove -y "$pkg_name"
                                            if [ $? -eq 0 ]; then
                                                success "$pkg_name entfernt."
                                                # Nach Entfernung zurück ins Haupt-DNF-Menü
                                                break
                                            else
                                                error "Entfernen fehlgeschlagen."
                                            fi
                                        else
                                            warn "Abgebrochen."
                                        fi
                                        pause
                                        ;;
                                    0) break ;;
                                    *) error "Ungültige Auswahl."; pause ;;
                                esac
                            done
                            ;;
                        0) break ;;
                    esac
                done ;;
            5) sudo journalctl --vacuum-size=200M; info "Starte Logrotate..."; sudo logrotate /etc/logrotate.conf && success "Logrotate durchgeführt."; pause ;;
            6)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   System-Caches verwalten ${NC}"
                    sep
                    echo -e "${YELLOW} Löscht temporäre Dateien${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Gaming Caches löschen (Vulkan/Shader)"
                    echo -e "${CYAN} 2)${NC} Kompletter User-Cache (.cache/)"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück"
                    sep
                    read -p "> " c_choice
                    case "$c_choice" in
                        1) rm -rf "$HOME/.cache/vulkan" "$HOME/.cache/gl_shader" 2>/dev/null; success "Gaming Caches gelöscht."; pause ;;
                                              2)
                            echo -e "${YELLOW}${BOLD}WARNUNG: Löscht den gesamten .cache-Ordner!${NC}"
                            echo -e "${YELLOW}Betroffen sind temporäre Dateien von Anwendungen (z.B. Browser-Cache,${NC}"
                            echo -e "${YELLOW}Thumbnails, Paket-Manager-Caches). Ihre persönlichen Dokumente,${NC}"
                            echo -e "${YELLOW}Downloads, Bilder, Videos usw. bleiben erhalten.${NC}"
                            read -rp "Trotzdem den gesamten User-Cache löschen? (y/N): " cache_conf
                            if [[ "$cache_conf" =~ ^[Yy]$ ]]; then
                                rm -rf "$HOME/.cache/"*
                                success "User-Cache gelöscht."
                            else
                                warn "Abgebrochen."
                            fi
                            pause ;;
                        0) break ;;
                    esac
                done ;;
                          7)
                while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Vorinstallierte Apps (Bloatware) entfernen ${NC}"
                 sep
                 echo -e "${YELLOW} Deinstalliert ungenutzte Standard-Programme${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} Spiele & Unterhaltung"
                 echo -e "${CYAN} 2)${NC} KDE PIM / Akonadi"
                 echo -e "${CYAN} 3)${NC} Software-Center & Paketverwaltung"
                 echo -e "${CYAN} 4)${NC} Netzwerk & Remote"
                 echo -e "${CYAN} 5)${NC} KDE Dienstprogramme & Systemtools"
                 echo -e "${CYAN} 6)${NC} VM-Gäste & Installationshilfen"
                 sep
                 echo -e "${CYAN} 0)${NC} Zurück"
                 sep
                 read -p "> " uchoice
                 case "$uchoice" in
                   1) confirm_and_remove "Spiele & Unterhaltung" "kmines kmahjongg kpat elisa-player neochat gwenview dragon kamoso" ;;
                   2) confirm_and_remove "KDE PIM / Akonadi" "akonadi* kdepim-* kleopatra korganizer incidenceeditor akregator kmail kaddressbook" ;;
                   3) confirm_and_remove "Software-Center" "plasma-discover plasma-discover-flatpak plasma-discover-kns plasma-discover-libs plasma-discover-notifier plasma-discover-offline-updates plasma-discover-packagekit flatpak-kcm" ;;
                   4) confirm_and_remove "Netzwerk & Remote" "kde-connect krdc krdc-libs krfb krfb-libs krdp krdp-libs kdenetwork-filesharing kio-gdrive" ;;
                   5) confirm_and_remove "KDE Dienstprogramme" "mediawriter kamera kcharselect kfind kolourpaint kolourpaint-libs kasumi-common kasumi-unicode khelpcenter plasma-systemmonitor kactivitymanagerd kscreen kscreenlocker ksysguard ksysguardd kded kded5 kdebugsettings kwrite plasma-welcome qrca skanpage kmouth" ;;
                   6) confirm_and_remove "VM-Gäste & Installationshilfen" "virtualbox-guest-additions open-vm-tools-desktop anaconda-install-env-deps anaconda-live initial-setup-gui initial-setup-gui-wayland-plasma livesys-scripts anaconda-core anaconda-tui anaconda-webui" ;;
                   0) break ;;
                   *) error "Ungültige Auswahl."; pause ;;
                 esac
                done ;;
            8) smart_disk_check ;;
                        9)
               info "Prüfe Hardware für TRIM..."
               RAW_SOURCE=$(findmnt -no SOURCE /)
               CLEAN_DEV=$(echo "$RAW_SOURCE" | sed 's/\[.*\]//' | xargs basename)
               PARENT_DEV=$(lsblk -no PKNAME "/dev/$CLEAN_DEV" 2>/dev/null | head -n1 | xargs)
               [[ -z "$PARENT_DEV" ]] && PARENT_DEV="$CLEAN_DEV"

               # Prüfen, ob der Pfad /sys/block/.../queue/rotational existiert
               if [[ ! -f "/sys/block/$PARENT_DEV/queue/rotational" ]]; then
                   warn "Kann nicht feststellen, ob es sich um eine SSD/HDD handelt. Überspringe TRIM."
               elif [[ $(cat "/sys/block/$PARENT_DEV/queue/rotational" 2>/dev/null) == "0" ]]; then
                   sudo fstrim -av
                   success "TRIM ausgeführt."
               else
                   warn "HDD erkannt. TRIM wird nicht durchgeführt (nicht nötig)."
               fi
               pause ;;
            10) manage_hd_idle ;;
            11)
                while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Btrfs-Wartungsmenü ${NC}"
                    sep
                    echo -e "${YELLOW} Pflege des Btrfs-Dateisystems der Root-Partition.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Scrub starten   (Dateisystem Fehlerprüfung)"
                    echo -e "${CYAN} 2)${NC} Scrub Status    (Fortschritt der Prüfung anzeigen)"
                    echo -e "${CYAN} 3)${NC} Balance (sanft) (Daten neu anordnen für mehr Platz)"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück"
                    sep
                    read -p "> " btrfs_choice
                    case "$btrfs_choice" in
                        1) sudo btrfs scrub start /; success "Scrub gestartet."; pause ;;
                        2) sudo btrfs scrub status / | show_with_pager; pause ;;
                                               3)
                            echo -e "${YELLOW}Hinweis: Eine Balance kann je nach Datenmenge lange dauern${NC}"
                            echo -e "${YELLOW}und die Platte belasten. Sie ist in der Regel sicher, aber${NC}"
                            echo -e "${YELLOW}es wird empfohlen, vorher ein Backup wichtiger Daten zu haben.${NC}"
                            read -rp "Balance starten? (y/N): " balance_confirm
                            if [[ "$balance_confirm" =~ ^[Yy]$ ]]; then
                                sudo btrfs balance start -dusage=10 -musage=10 /
                                success "Balance ausgeführt."
                            else
                                warn "Abgebrochen."
                            fi
                            pause ;;
                        0) break ;;
                    esac
                done ;;
               12)
               clear
               sep
               echo -e "${WHITE}${BOLD}   System Health & Infos ${NC}"
               sep
               echo -e "${YELLOW} Überblick über kritische Systemzustände${NC}"
               sep
               echo -e "${BOLD}Fehlgeschlagene Services:${NC}"
               failed_services=$(systemctl list-units --state=failed --no-legend 2>/dev/null)
               if [ -z "$failed_services" ]; then
                   echo "Alles okay."
               else
                   echo "$failed_services"
               fi
               echo -e "\n${BOLD}Speicherbelegung:${NC}"; df -h -t ext4 -t xfs -t btrfs
               echo -e "\n${BOLD}SELinux Status:${NC}"; getenforce
               echo -e "\n${BOLD}Firewall Status:${NC}"; systemctl is-active firewalld

               echo -e "\n${BOLD}Display Server (Wayland/X11):${NC}"
               loginctl list-sessions | awk '/seat/ {print $1}' | head -n1 | xargs -I {} loginctl show-session {} -p Type --value 2>/dev/null || echo "Unbekannt"

               sep

               # Untermenü für zusätzliche Systeminformationen
               while true; do
                    echo -e "${CYAN}Weitere Optionen:${NC}"
                    echo -e "${CYAN} 1)${NC} Letzte SELinux-Verweigerungen anzeigen"
                    echo -e "${CYAN} 2)${NC} Hardware-Übersicht (inxi)"
                    echo -e "${CYAN} 3)${NC} Detaillierter HTML-Hardware-Bericht (lshw)"
                    echo -e "${CYAN} 0)${NC} Zurück zum Hauptmenü"
                    read -rp "Ihre Wahl: " health_choice
                    case "$health_choice" in
                        1)
                            info "Zeige letzte SELinux-Verweigerungen..."
                            sudo SYSTEMD_COLORS=1 journalctl -t setroubleshoot -n 20 --no-pager | show_with_pager
                            pause
                            ;;
                        2)
                            # Prüfen, ob inxi installiert ist
                            if ! command -v inxi >/dev/null 2>&1; then
                                echo -e "${YELLOW}inxi ist nicht installiert. Möchtest du es installieren? (y/N):${NC}"
                                read -rp "> " inst_inxi
                                if [[ "$inst_inxi" =~ ^[Yy]$ ]]; then
                                    sudo dnf install -y inxi
                                else
                                    warn "Installation abgebrochen."
                                    pause
                                    continue
                                fi
                            fi
                            ask_and_start "inxi -Fxxxrz" "inxi"
                            ;;
                        3)
                            # Prüfen, ob lshw installiert ist
                            if ! command -v lshw >/dev/null 2>&1; then
                                echo -e "${YELLOW}lshw ist nicht installiert. Möchtest du es installieren? (y/N):${NC}"
                                read -rp "> " inst_lshw
                                if [[ "$inst_lshw" =~ ^[Yy]$ ]]; then
                                    sudo dnf install -y lshw
                                else
                                    warn "Installation abgebrochen."
                                    pause
                                    continue
                                fi
                            fi
                            local user_home=$(eval echo "~${SUDO_USER:-$USER}")
                            local report_file="$user_home/hardware-report.html"
                            info "Erstelle HTML-Bericht mit lshw (benötigt sudo)..."
                            sudo lshw -html > "$report_file"
                            sudo chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$report_file"
                            success "Bericht erstellt: $report_file"
                            echo -e "${YELLOW}Du kannst ihn mit einem Browser öffnen.${NC}"
                            pause
                            ;;
                        0)
                            break
                            ;;
                        *)
                            error "Ungültige Auswahl."
                            ;;
                    esac
                    echo ""
               done
               pause ;;
                        13)
               while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Boot-Zeit Analyse & Bootloader ${NC}"
                    sep
                    echo -e "${YELLOW} Analysiert die Boot-Zeit und passt GRUB an.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} Boot-Zeit Analyse (systemd-analyze)"
                    echo -e "${CYAN} 2)${NC} GRUB Bootverhalten anpassen"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück"
                    sep
                    read -rp "> " boot_choice
                    case "$boot_choice" in
                        1)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   Boot-Zeit Analyse ${NC}"
                            sep
                            systemd-analyze
                            echo -e "\n${YELLOW}Zeitaufschlüsselung der Dienste (Top 20):${NC}"
                            systemd-analyze blame | head -n 20
                            sep
                            pause
                            ;;
                        2)
                            clear
                            sep
                            echo -e "${WHITE}${BOLD}   GRUB Bootverhalten anpassen ${NC}"
                            sep
                            echo -e "${YELLOW}Legt fest, ob das GRUB-Menü beim Start angezeigt wird und wie lange.${NC}"
                            sep
                            echo -e "${CYAN} 1)${NC} Menü immer sichtbar (mit Timeout)"
                            echo -e "${CYAN} 2)${NC} Menü automatisch verstecken (nur bei Bedarf)"
                            read -rp "Wahl (1/2): " grub_mode

                            local timeout_value=""
                            if [[ "$grub_mode" == "1" ]]; then
                                read -rp "Timeout in Sekunden (Standard 5): " timeout_input
                                timeout_value=${timeout_input:-5}
                                # GRUB_TIMEOUT_STYLE=menu
                                sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
                            else
                                read -rp "Timeout in Sekunden (0 = sofort booten, Standard 2): " timeout_input
                                timeout_value=${timeout_input:-2}
                                # GRUB_TIMEOUT_STYLE=hidden
                                sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
                            fi

                            # Setze GRUB_TIMEOUT
                            sudo sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$timeout_value/" /etc/default/grub

                            # Falls die Zeilen nicht existieren, anhängen
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

                            echo -e "${YELLOW}Neue GRUB-Konfiguration wird generiert...${NC}"
                            sudo grub2-mkconfig -o /boot/grub2/grub.cfg
                            success "GRUB-Konfiguration aktualisiert."
                            echo -e "${YELLOW}Die Änderungen werden beim nächsten Neustart wirksam.${NC}"
                            pause
                            ;;
                        0) break ;;
                        *) error "Ungültige Auswahl."; pause ;;
                    esac
               done ;;
            14)

               # Abhängigkeitscheck für Stresstests
               local s_missing=()
               command -v s-tui >/dev/null 2>&1 || s_missing+=("s-tui")
               command -v memtester >/dev/null 2>&1 || s_missing+=("memtester")
               command -v stress-ng >/dev/null 2>&1 || s_missing+=("stress-ng")

               if [ ${#s_missing[@]} -ne 0 ]; then
                   echo -e "${YELLOW}[INFO] Für Stresstests werden zusätzliche Tools benötigt:${NC}"
                   for item in "${s_missing[@]}"; do echo -e "  - $item"; done
                   read -rp "Möchten Sie diese jetzt installieren? (y/N): " s_choice
                   if [[ "$s_choice" =~ ^[Yy]$ ]]; then
                       sudo dnf install -y "${s_missing[@]}"
                   else
                       warn "Installation abgebrochen. Kehre zum Hauptmenü zurück."
                       pause
                       continue
                   fi
               fi

               while true; do
                    clear
                    sep
                    echo -e "${WHITE}${BOLD}   Stresstest & Monitoring ${NC}"
                    sep
                    echo -e "${YELLOW} Überprüfung der Systemstabilität und Hardware-Last.${NC}"
                    sep
                    echo -e "${CYAN} 1)${NC} s-tui (CPU Monitoring & Stress GUI)"
                    echo -e "${CYAN} 2)${NC} memtester (Arbeitsspeicher-Stabilitätstest)"
                    echo -e "${CYAN} 3)${NC} stress-ng (Erweiterter System-Stresstest)"
                    sep
                    echo -e "${CYAN} 0)${NC} Zurück"
                    sep
                    read -p "> " st_choice
                    case "$st_choice" in
                            1)
                            info "Starte s-tui..."
                            ask_and_start "sudo s-tui" "s-tui"
                            success "s-tui wurde gestartet."
                            ;;
                            2)
                            read -rp "Wie viel RAM soll getestet werden? (z.B. 1024M oder 2G): " m_ram
                            read -rp "Wie viele Durchläufe sollen stattfinden?: " m_runs
                            info "Starte memtester..."
                            ask_and_start "sudo memtester \"$m_ram\" \"$m_runs\"" "memtester"
                            success "memtester wurde gestartet."
                            ;;
                            3)
                            # Anzahl der CPU-Threads automatisch ermitteln
                            local cpu_threads=$(nproc)
                            read -rp "Dauer des Tests (z.B. 60s, 5m, 1h): " s_time
                            echo -e "Welcher Test soll durchgeführt werden?"
                            echo -e " 1) CPU-Intensiv (Integer, alle Kerne) – gut für erste Stabilität"
                            echo -e " 2) FPU + Cache (Matrix, L3) – optimal für Curve Optimizer"
                            echo -e " 3) RAM & Cache – prüft Speichercontroller und Infinity Fabric"
                            read -rp "Wahl (1/2/3): " test_wahl

                            local test_cmd=""
                            case $test_wahl in
                                1)
                                    test_cmd="sudo stress-ng --cpu $cpu_threads --timeout $s_time --verify --verbose"
                                    ;;
                                2)
                                    test_cmd="sudo stress-ng --matrix $cpu_threads --cache $cpu_threads --timeout $s_time --verify --verbose"
                                    ;;
                                3)
                                    # Bei RAM-Test weniger Worker, aber hohe Speicherauslastung
                                    test_cmd="sudo stress-ng --vm 4 --vm-bytes 80% --cache 8 --timeout $s_time --verify --verbose"
                                    ;;
                                *)
                                    error "Ungültige Auswahl"
                                    pause
                                    continue
                                    ;;
                            esac

                            info "Starte stress-ng mit: $test_cmd"
                            ask_and_start "$test_cmd" "stress-ng"
                            success "stress-ng wurde gestartet."
                            ;;
                        0) break ;;
                        *) error "Ungültige Auswahl."; pause ;;
                    esac
               done ;;
            d) desktop_settings_menu ;;
            r) while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Paket Reparatur Werkzeuge ${NC}"
                 sep
                 echo -e "${YELLOW} Hilft bei Problemen mit der Paketverwaltung (DNF/RPM).${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} DNF Check        (Prüft Abhängigkeiten auf Fehler)"
                 echo -e "${CYAN} 2)${NC} Duplikate suchen (Findet doppelte Pakete)"
                 echo -e "${CYAN} 3)${NC} RPM DB Rebuild   (Repariert RPM-Datenbank)"
                 echo -e "${CYAN} 4)${NC} RPM Verify (-Va) (Vergleicht Dateien mit Orig.)"
                 sep
                 echo -e "${CYAN} 0)${NC} Zurück"
                 sep
                 read -p "> " r1
                 case $r1 in
                   1) info "Starte DNF Check..."; sudo dnf check && success "DNF Check abgeschlossen."; pause ;;
                   2) info "Suche Duplikate..."; sudo dnf repoquery --duplicates || success "Keine Duplikate gefunden."; pause ;;
                                      3)
                       echo -e "${YELLOW}Ein Rebuild der RPM-Datenbank ist normalerweise sicher,${NC}"
                       echo -e "${YELLOW}kann aber im laufenden Betrieb zu kurzen Sperren führen.${NC}"
                       read -rp "RPM DB Rebuild durchführen? (y/N): " rpm_confirm
                       if [[ "$rpm_confirm" =~ ^[Yy]$ ]]; then
                           info "RPM DB Rebuild..."; sudo rpm --rebuilddb && success "RPM Datenbank neu aufgebaut."
                       else
                           warn "Abgebrochen."
                       fi
                       pause ;;
                   4) info "RPM Verify läuft..."; sudo rpm -Va | show_with_pager; success "Verifizierung beendet."; pause ;;
                   0) break ;;
                 esac
               done ;;
            s) service_manager ;;
            n) while true; do
                 clear
                 sep
                 echo -e "${WHITE}${BOLD}   Netzwerk Werkzeuge ${NC}"
                 sep
                 echo -e "${YELLOW} Nützliche Tools zur Diagnose der Netzwerkverbindung.${NC}"
                 sep
                 echo -e "${CYAN} 1)${NC} IP Adressen      (Lokal & Extern)"
                 echo -e "${CYAN} 2)${NC} DNS Cache leeren (Bei Namensauflösungs-Problemen)"
                 echo -e "${CYAN} 3)${NC} Offene Ports     (Zeigt lauschende Dienste/Sockets)"
                 echo -e "${CYAN} 4)${NC} nethogs          (Netzwerk-Bandbreite pro Prozess)"
                 echo -e "${CYAN} 5)${NC} nload            (Netzwerk-Auslastung in Echtzeit)"
                 sep
                 echo -e "${CYAN} 0)${NC} Zurück"
                 sep
                 read -p "> " n1
                 case $n1 in
                   1) echo -en "Lokal: "; hostname -I; echo -en "Extern: "; curl -s https://ifconfig.me; echo ""; pause ;;
                   2) info "Leere DNS Cache..."; sudo resolvectl flush-caches && success "DNS Cache geleert."; pause ;;
                   3) info "Zeige offene Ports..."; sudo ss -tulpn | grep LISTEN | show_with_pager; pause ;;
                   4)
                       # Prüfen, ob nethogs installiert ist
                       if ! command -v nethogs >/dev/null 2>&1; then
                           echo -e "${YELLOW}nethogs ist nicht installiert. Möchtest du es installieren? (y/N):${NC}"
                           read -rp "> " inst_nethogs
                           if [[ "$inst_nethogs" =~ ^[Yy]$ ]]; then
                               sudo dnf install -y nethogs
                           else
                               warn "Installation abgebrochen. Kehre zurück."
                               pause
                               continue
                           fi
                       fi
                       # Modusauswahl
                       echo -e "${YELLOW}Welcher Modus?${NC}"
                       echo -e " 1) Normaler Modus (zeigt aktuelle Verbindungen)"
                       echo -e " 2) Tracemode (zeigt zusätzlich Paket-Traces)"
                       read -rp "Wahl (1/2): " mode
                       if [[ "$mode" == "2" ]]; then
                           nethogs_cmd="sudo nethogs -t"
                       else
                           nethogs_cmd="sudo nethogs"
                       fi
                       # Hinweis anzeigen
                       echo -e "${CYAN}${BOLD}Hinweis zu nethogs:${NC}"
                       echo -e "  - Umschalten zwischen kb/s, kb, b, mb: drücke ${WHITE}${BOLD}m${NC}"
                       echo -e "  - Sortierung nach Rx/Tx: drücke ${WHITE}${BOLD}s${NC} (mehrmals)"
                       echo -e "  - Beenden: ${WHITE}${BOLD}q${NC}"
                       ask_and_start "$nethogs_cmd" "nethogs"
                       ;;
                    5)
                       # Prüfen, ob nload installiert ist
                       if ! command -v nload >/dev/null 2>&1; then
                           echo -e "${YELLOW}nload ist nicht installiert. Möchtest du es installieren? (y/N):${NC}"
                           read -rp "> " inst_nload
                           if [[ "$inst_nload" =~ ^[Yy]$ ]]; then
                               sudo dnf install -y nload
                           else
                               warn "Installation abgebrochen. Kehre zurück."
                               pause
                               continue
                           fi
                       fi
                       # Einstellungen für nload
                       echo -e "${YELLOW}Einstellungen für nload:${NC}"
                       read -rp "Refresh-Rate in Millisekunden (Standard 500): " refresh
                       refresh=${refresh:-500}
                       echo -e "Einheit für die Anzeige:"
                       echo -e " 1) Bytes"
                       echo -e " 2) Bits"
                       read -rp "Wahl (1/2): " unit_choice
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
                echo -e "${WHITE}${BOLD}   Wartungs-Logs einsehen ${NC}"
                sep
                echo -e "${YELLOW} Zeigt die Protokolle vergangener Wartungsdurchläufe${NC}"
                sep
                mapfile -t FILES < <(sudo ls -1t "$SYS_LOG_DIR"/maintenance-*.log 2>/dev/null)
                for i in "${!FILES[@]}"; do printf "${CYAN} %d)${NC} %s\n" "$((i+1))" "$(basename "${FILES[i]}")"; done
                sep
                sep
                read -rp "Wahl (d=löschen, 0=zurück): " sel
                if [[ "$sel" == "d" ]]; then sudo rm -f "$SYS_LOG_DIR"/*.log; elif [[ "$sel" =~ ^[0-9]+$ && "$sel" -gt 0 ]]; then sudo cat "${FILES[sel-1]}" | show_with_pager; fi; pause ;;
            k) kernel_menu ;;
            0) exit 0 ;;
            *) error "Ungültig."; sleep 1 ;;
        esac
    done
}

# Installations-Check
if [[ "$0" != "/usr/local/bin/maint" && ! -f "/usr/local/bin/maint" ]]; then
    read -rp "Als 'maint' installieren? [y/N]: " inst
    [[ "$inst" =~ ^[Yy]$ ]] && sudo cp "$0" /usr/local/bin/maint && sudo chmod +x /usr/local/bin/maint && success "Installiert!" && pause
fi

# Root-Rechte-Check
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Bitte mit 'sudo' starten.${NC}"
    exit 1
fi

main_menu
