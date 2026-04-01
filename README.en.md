# Fedora Maintenance Pro (maint) 

`maint` is a powerful, interactive Bash script designed to automate system maintenance, optimization, and diagnostics on Fedora Linux. It simplifies complex terminal tasks into a user-friendly menu.

> **Note:** The script interface is currently in **German**, but it is designed to be intuitive for Linux users worldwide.

##  Key Features
- **Autopilot:** Fully automated maintenance (DNF updates, Flatpak repair, TRIM, Journal cleanup).
- **Backup & Restore:** Easily backup system configurations, RPM package lists, and KDE Plasma settings.
- **Hardware Diagnostics:** Check SMART status of drives and manage HDD spindown (`hd-idle`).
- **Kernel Optimization:** Support for the high-performance **CachyOS Kernel** (incl. x86_64_v3 architecture check).
- **System Analysis:** Boot time analysis, stress testing, and detailed system health reports.
- **Desktop Fixes:** Quickly reset KDE Plasma, Dolphin, or KWin configurations if they become unstable.

##  Quick Start
You can download and run the script with a single command:

```bash
curl -O https://raw.githubusercontent.com/HarlonOna/maint/main/maint.sh

chmod +x maint.sh

sudo ./maint.sh
```

Note: Upon the first run, the script offers to install itself to /usr/local/bin/maint for easy access.
Just type sudo maint to start it afterwards.

## Prerequisites

This script is optimized for Fedora Linux. Some advanced features require additional tools (like smartmontools or hd-idle). The script will detect missing dependencies and offer to install them for you.

## License

This project is licensed under the GPL-3.0 License.
