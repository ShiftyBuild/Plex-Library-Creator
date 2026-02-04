# PlexUpdate.sh - Creates libraries in Plex to match folders in your directory structure. 

Installation
---

Clone or download the script:

curl -O https://raw.githubusercontent.com/ShiftyBuild/plex-library-audit/main/PlexUpdate.sh
chmod +x PlexUpdate.sh
---

**PlexUpdate.sh** is an interactive Plex library auditing and maintenance script.  
It inspects your existing Plex libraries, validates their filesystem paths, scans media roots for *uncovered directories*, and optionally helps you **exclude** them or **create new Plex libraries** using an existing library as a template.

This is designed for users who manage large or evolving media collections and want to keep Plex in sync without guesswork.

---

## Features

- 🔍 **Audit existing Plex libraries**
  - Lists all libraries and their configured paths
  - Validates that each path exists on disk
- 📂 **Scan media roots for uncovered directories**
  - Detects folders not owned by any Plex library
  - Uses normalized paths to avoid false mismatches
- 🚫 **Persistent exclusion list**
  - Mark directories as “do not add”
  - Stored safely in a local config file
- ➕ **Optional library creation**
  - Interactively create new libraries for uncovered directories
  - Copy type / agent / scanner / language from an existing library
- 🧪 **Dry-run mode**
  - Preview all actions without making changes
- 💾 **Saved configuration**
  - Remembers Plex host, token, scan roots, exclusions, and templates
- 🔐 **Safe by default**
  - No POST requests unless explicitly enabled
  - Config file permissions locked down

---

## Requirements

The script is written for **Linux / macOS** and requires:

- `bash` (4.x+ recommended)
- `curl`
- `xmllint`
- `find`
- `sed`
- `awk`
- `grep`
- `realpath`

Most of these are available by default on Linux.  
On macOS, you may need:

bash
brew
install
coreutils
libxml2

---
Usage
./PlexUpdate.sh [options]

Common examples

Audit Plex libraries and scan default root (/mnt/Other):

./PlexUpdate.sh


Scan specific roots and interactively handle new folders:

./PlexUpdate.sh --scan-roots "/mnt/Media,/mnt/Downloads" --add-new


Preview everything without making changes:

./PlexUpdate.sh --scan-roots /mnt/Media --add-new --dry-run


Reset saved configuration:

./PlexUpdate.sh --reset-config

Options
Option	Description
--version	Print version and exit
--dry-run	Do not POST changes (show what would happen)
--scan-roots "<a,b,c>"	Comma-separated roots to scan
--scan-roots <path>	Can be specified multiple times
--add-new	Enable interactive prompts and library creation
--reset-config	Remove saved config and exit
--no-save	Do not write config changes
-h, --help	Show help
---
How It Works

Connects to Plex

Uses http://<host>:<port>

Automatically prompts for X-Plex-Token if required

Fetches library sections

Reads library IDs, titles, types, and locations

Normalizes paths

Prevents mismatches caused by symlinks or trailing slashes

Scans root directories

Compares top-level folders against Plex library paths

Handles uncovered directories

Exclude permanently

Skip once

Add as a new library (optional)

Creates new libraries

Uses an existing library as a template

Supports dry-run mode
---

Configuration

Config is stored at:

~/.config/plex-library-audit/config

---
Saved values include:

Plex host & port

Plex authentication token

Scan roots

Excluded directories (do-not-add list)

Template library settings

Permissions are set to:

chmod 600
---

Safety Notes

No libraries are created unless --add-new is used

No changes are made in --dry-run mode

Exclusions are explicit and persistent

Library creation is fully interactive

POST requests are only made when required

This script is intentionally conservative.
---

Troubleshooting
Failed to fetch /library/sections

Plex is unreachable or wrong host/port

Plex requires authentication → enter X-Plex-Token

Paths show as missing

Plex paths may not exist on the machine running the script

Check mounts, permissions, or container paths

Nothing matches existing libraries

Ensure scan roots are parents of Plex library paths

Normalization removes trailing slashes and resolves symlinks
