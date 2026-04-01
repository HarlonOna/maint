# maint
Comprehensive Maintenance &amp; Diagnostic Tool for Fedora

# Fedora Maintenance Pro (maint)

`maint` ist ein leistungsstarkes, interaktives Bash-Script zur Automatisierung der Systempflege unter Fedora Linux. Es kombiniert tiefgreifende Systemwartung mit Hardware-Diagnose und Optimierungstools.

## Hauptfunktionen
- **Autopilot:** Vollautomatische Wartung (DNF, Flatpak, Journal-Cleanup, TRIM).
- **Backup & Restore:** Sicherung von System-Konfigurationen und Paketlisten.
- **Hardware-Check:** SMART-Status von Festplatten und HDD-Spindown-Steuerung (`hd-idle`).
- **Kernel-Optimierung:** Unterstützung für den hochoptimierten **CachyOS-Kernel** (inkl. x86_64_v3 Check).
- **System-Analyse:** Bootzeit-Analyse, Stresstests und detaillierte System-Infos.
- **Desktop-Fixes:** Schnelles Zurücksetzen von KDE Plasma- oder Dolphin-Einstellungen.

## Installation & Start
Du kannst das Script mit einem einzigen Befehl herunterladen und starten:


curl -O

chmod +x maint

sudo ./maint


Hinweis: Beim ersten Start bietet das Script an, sich dauerhaft als /usr/local/bin/maint zu installieren, damit du es einfach durch Tippen von maint starten kannst.


🛠 Voraussetzungen

Das Script ist für Fedora Linux optimiert. Einige Funktionen benötigen zusätzliche Pakete (wie smartmontools oder hd-idle), die das Script auf Wunsch automatisch zur Installation anbietet.
⚖️ Lizenz

Dieses Projekt ist unter der GPL-3.0 Lizenz lizenziert.
