#!/usr/bin/env bash
set -euo pipefail

########################################
# Script metadata
########################################
SCRIPT_NAME="PlexUpdate.sh"
SCRIPT_VERSION="1.7.0"
SCRIPT_DATE="2026-02-03"

########################################
# Defaults / globals
########################################
STATUS_CODE=""

DRY_RUN=false
ADD_NEW=false
NO_SAVE=false
RESET_CONFIG=false
SCAN_ROOTS=()     # array

########################################
# Color handling (bright ANSI)
########################################
COLOR_ENABLED=false

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  COLOR_ENABLED=true
fi

if $COLOR_ENABLED; then
  BOLD="\033[1m"
  RESET="\033[0m"
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  CYAN="\033[36m"
  BWHITE="\033[1;37m"
else
  BOLD=""
  RESET=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  BWHITE=""
fi

cecho() {
  local color="$1"; shift
  printf "%b%s%b\n" "$color" "$*" "$RESET"
}

die() { cecho "$RED" "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
trim() { echo "$*" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

prompt() {
  local var_name="$1" label="$2" default="${3:-}" secret="${4:-false}"
  local input=""
  local prompt_text

  if $COLOR_ENABLED; then
    prompt_text="${BWHITE}${label}${RESET}"
  else
    prompt_text="$label"
  fi

  if [[ -n "$default" ]]; then
    if [[ "$secret" == "true" ]]; then
      printf "%b" "$prompt_text [$default]: "
      read -r -s input
      echo
    else
      printf "%b" "$prompt_text [$default]: "
      read -r input
    fi
    input="$(trim "$input")"
    [[ -z "$input" ]] && input="$default"
  else
    if [[ "$secret" == "true" ]]; then
      printf "%b" "$prompt_text: "
      read -r -s input
      echo
    else
      printf "%b" "$prompt_text: "
      read -r input
    fi
    input="$(trim "$input")"
  fi

  printf -v "$var_name" "%s" "$input"
}

confirm() {
  local label="$1" ans=""
  local prompt_text

  if $COLOR_ENABLED; then
    prompt_text="${BWHITE}${label}${RESET}"
  else
    prompt_text="$label"
  fi

  printf "%b" "$prompt_text [y/N]: "
  read -r ans
  ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

urlencode() {
  local s="$1" out="" ch hex
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-]) out+="$ch" ;;
      ' ') out+='%20' ;;
      *) printf -v hex '%%%02X' "'$ch"; out+="$hex" ;;
    esac
  done
  echo "$out"
}

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION ($SCRIPT_DATE)

Usage:
  $SCRIPT_NAME [options]

Options:
  --version                  Print version and exit
  --dry-run                  Do not POST changes (show what would happen)
  --scan-roots "<a,b,c>"     Comma-separated roots to scan for uncovered dirs
  --scan-roots <path>        Can be specified multiple times
  --add-new                  Enable interactive add/exclude prompts and create new libraries (if chosen)
  --reset-config             Remove saved config and exit
  --no-save                  Do not write config changes
  -h, --help                 Show help

Notes:
  - Default scan root (if none specified and none saved): /mnt/Other
  - Tracks excluded folders (do-not-add) persistently in config.

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --scan-roots "/mnt/Other" --add-new
  $SCRIPT_NAME --scan-roots "/mnt/Other,/mnt/Media" --add-new --dry-run
EOF
}

# Normalize a path for consistent prefix comparisons.
norm_path() {
  local p="${1%/}"
  realpath -m -- "$p" 2>/dev/null || echo "$p"
}

# XPath 1.0-safe attribute extraction.
extract_xpath_attr_lines() {
  local xml="$1"
  local xpath="$2"
  local attr="$3"

  local raw
  raw="$(echo "$xml" | xmllint --xpath "$xpath" - 2>/dev/null || true)"

  # Fallback for some Plex/xmllint combos
  if [[ -z "$raw" ]]; then
    raw="$(echo "$xml" | xmllint --xpath "//Location/@$attr" - 2>/dev/null || true)"
  fi

  echo "$raw" \
    | grep -o "$attr=\"[^\"]*\"" \
    | sed -E "s/^$attr=\"//; s/\"$//"
}

########################################
# Config
########################################
CONFIG_DIR="$HOME/.config/plex-library-audit"
CONFIG_FILE="$CONFIG_DIR/config"

PLEX_HOST=""
PLEX_PORT="32400"
PLEX_TOKEN=""
SAVED_SCAN_ROOTS=""

EXCLUDED_DIRS_NL=""
EXCLUDED_DIRS=()

TEMPLATE_TYPE=""
TEMPLATE_AGENT=""
TEMPLATE_SCANNER=""
TEMPLATE_LANG=""

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  EXCLUDED_DIRS=()
  if [[ -n "${EXCLUDED_DIRS_NL:-}" ]]; then
    while IFS= read -r line; do
      line="$(trim "$line")"
      [[ -n "$line" ]] && EXCLUDED_DIRS+=("$(norm_path "$line")")
    done <<< "$EXCLUDED_DIRS_NL"
  fi

  TEMPLATE_TYPE="${TEMPLATE_TYPE:-}"
  TEMPLATE_AGENT="${TEMPLATE_AGENT:-}"
  TEMPLATE_SCANNER="${TEMPLATE_SCANNER:-}"
  TEMPLATE_LANG="${TEMPLATE_LANG:-}"
}

save_config() {
  $NO_SAVE && return 0
  mkdir -p "$CONFIG_DIR"

  local nl=""
  if [[ "${#EXCLUDED_DIRS[@]}" -gt 0 ]]; then
    nl="$(printf "%s\n" "${EXCLUDED_DIRS[@]}")"
  fi

  local escaped
  escaped="$(printf "%s" "$nl" | sed "s/'/'\\\\''/g")"

  cat >"$CONFIG_FILE" <<EOF
PLEX_HOST="$PLEX_HOST"
PLEX_PORT="$PLEX_PORT"
PLEX_TOKEN="$PLEX_TOKEN"
SAVED_SCAN_ROOTS="$SAVED_SCAN_ROOTS"
EXCLUDED_DIRS_NL=\$'$escaped'
TEMPLATE_TYPE="$TEMPLATE_TYPE"
TEMPLATE_AGENT="$TEMPLATE_AGENT"
TEMPLATE_SCANNER="$TEMPLATE_SCANNER"
TEMPLATE_LANG="$TEMPLATE_LANG"
EOF
  chmod 600 "$CONFIG_FILE"
}

reset_config() {
  rm -f "$CONFIG_FILE"
  cecho "$YELLOW" "Removed config: $CONFIG_FILE"
}

is_excluded() {
  local needle
  needle="$(norm_path "$1")"
  for e in "${EXCLUDED_DIRS[@]}"; do
    [[ "$needle" == "$(norm_path "$e")" ]] && return 0
  done
  return 1
}

add_exclude() {
  local p
  p="$(norm_path "$1")"
  is_excluded "$p" && return 0
  EXCLUDED_DIRS+=("$p")
  save_config
}

########################################
# Arg parsing
########################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      echo "$SCRIPT_NAME v$SCRIPT_VERSION ($SCRIPT_DATE)"
      exit 0
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --add-new) ADD_NEW=true; shift ;;
    --no-save) NO_SAVE=true; shift ;;
    --reset-config) RESET_CONFIG=true; shift ;;
    --scan-roots)
      shift
      [[ $# -gt 0 ]] || die "--scan-roots requires a value"
      val="$1"
      if [[ "$val" == *","* ]]; then
        IFS=',' read -r -a parts <<< "$val"
        for p in "${parts[@]}"; do
          p="$(trim "$p")"; [[ -n "$p" ]] && SCAN_ROOTS+=("$p")
        done
      else
        SCAN_ROOTS+=("$val")
      fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

if $RESET_CONFIG; then
  reset_config
  exit 0
fi

########################################
# Dependencies
########################################
need_cmd curl
need_cmd xmllint
need_cmd find
need_cmd sed
need_cmd awk
need_cmd realpath
need_cmd grep

########################################
# Banner
########################################
cecho "$CYAN" "======================================"
cecho "$CYAN" "$SCRIPT_NAME  v$SCRIPT_VERSION"
cecho "$CYAN" "Built: $SCRIPT_DATE"
cecho "$CYAN" "======================================"
echo

########################################
# Prompts / Load config
########################################
load_config
DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "${DEFAULT_IP:-}" ]] || DEFAULT_IP="127.0.0.1"

prompt PLEX_HOST "Plex server hostname or IP" "${PLEX_HOST:-$DEFAULT_IP}"
prompt PLEX_PORT "Plex server port" "${PLEX_PORT:-32400}"
PLEX_URL="http://$PLEX_HOST:$PLEX_PORT"
PLEX_URL="${PLEX_URL%/}"

# Determine scan roots (CLI > saved > default /mnt/Other)
if [[ "${#SCAN_ROOTS[@]}" -eq 0 ]]; then
  if [[ -n "${SAVED_SCAN_ROOTS:-}" ]]; then
    IFS=',' read -r -a parts <<< "$SAVED_SCAN_ROOTS"
    for p in "${parts[@]}"; do
      p="$(trim "$p")"
      [[ -n "$p" ]] && SCAN_ROOTS+=("$p")
    done
  else
    SCAN_ROOTS=("/mnt/Other")
    SAVED_SCAN_ROOTS="/mnt/Other"
    cecho "$YELLOW" "Using default scan root: /mnt/Other"
    echo
  fi
fi

# Persist scan roots back if provided
if [[ "${#SCAN_ROOTS[@]}" -gt 0 ]]; then
  SAVED_SCAN_ROOTS="$(IFS=','; echo "${SCAN_ROOTS[*]}")"
fi
save_config

########################################
# HTTP helpers
########################################
plex_get() {
  local endpoint="$1"
  local outvar="$2"

  local tmp_body tmp_err tmp_code
  tmp_body="$(mktemp)"
  tmp_err="$(mktemp)"
  tmp_code="$(mktemp)"

  local -a args
  args=(
    -sS
    --connect-timeout 3
    --max-time 15
    -H "Accept: application/xml"
    -o "$tmp_body"
    --write-out "%{http_code}"
  )

  [[ -n "$PLEX_TOKEN" ]] && args+=( -H "X-Plex-Token: $PLEX_TOKEN" )

  if ! curl "${args[@]}" "$PLEX_URL$endpoint" 2>"$tmp_err" >"$tmp_code"; then
    echo "000" >"$tmp_code"
  fi

  STATUS_CODE="$(tr -d '\r\n' <"$tmp_code")"

  if [[ -z "$STATUS_CODE" || "$STATUS_CODE" == "000" ]]; then
    cecho "$RED" "curl failed for $PLEX_URL$endpoint"
    sed 's/^/  /' "$tmp_err" >&2
    rm -f "$tmp_body" "$tmp_err" "$tmp_code"
    return 1
  fi

  local body
  body="$(cat "$tmp_body")"
  printf -v "$outvar" '%s' "$body"

  rm -f "$tmp_body" "$tmp_err" "$tmp_code"
  return 0
}

plex_post() {
  local full_url="$1"
  local tmp_body tmp_err tmp_code
  tmp_body="$(mktemp)"
  tmp_err="$(mktemp)"
  tmp_code="$(mktemp)"

  local -a args
  args=(
    -sS
    --connect-timeout 3
    --max-time 30
    -X POST
    -H "Accept: application/xml"
    -o "$tmp_body"
    --write-out "%{http_code}"
  )

  [[ -n "$PLEX_TOKEN" ]] && args+=( -H "X-Plex-Token: $PLEX_TOKEN" )

  if ! curl "${args[@]}" "$full_url" 2>"$tmp_err" >"$tmp_code"; then
    echo "000" >"$tmp_code"
  fi

  STATUS_CODE="$(tr -d '\r\n' <"$tmp_code")"

  if [[ -z "$STATUS_CODE" || "$STATUS_CODE" == "000" ]]; then
    cecho "$RED" "curl failed for POST $full_url"
    sed 's/^/  /' "$tmp_err" >&2
    rm -f "$tmp_body" "$tmp_err" "$tmp_code"
    return 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body" "$tmp_err" "$tmp_code"
}

require_token_if_needed() {
  if [[ "$STATUS_CODE" == "401" || "$STATUS_CODE" == "403" ]]; then
    echo
    cecho "$YELLOW" "Plex requires authentication for this API call (HTTP $STATUS_CODE)."
    prompt PLEX_TOKEN "Enter Plex X-Plex-Token (input hidden)" "${PLEX_TOKEN:-}" "true"
    [[ -n "$PLEX_TOKEN" ]] || die "Token cannot be empty."
    save_config
  fi
}

########################################
# Fetch sections
########################################
cecho "$CYAN" "Fetching Plex library sections from:"
echo "  $PLEX_URL"
echo

SECTIONS_XML=""
plex_get "/library/sections" SECTIONS_XML || die "Plex not reachable at $PLEX_URL"

if [[ "$STATUS_CODE" == "401" || "$STATUS_CODE" == "403" ]]; then
  require_token_if_needed
  plex_get "/library/sections" SECTIONS_XML || die "Failed after token."
fi
[[ "$STATUS_CODE" == "200" ]] || die "Failed to fetch /library/sections (HTTP $STATUS_CODE)"

# Parse sections (XPath 1.0 safe)
extract_sections_attr_lines() {
  local attr="$1"
  echo "$SECTIONS_XML" \
    | xmllint --xpath "/MediaContainer/Directory/@$attr" - 2>/dev/null \
    | grep -o "$attr=\"[^\"]*\"" \
    | sed -E "s/^$attr=\"//; s/\"$//" \
    | sed '/^[[:space:]]*$/d'
}

mapfile -t SECTION_IDS    < <(extract_sections_attr_lines "key")
mapfile -t SECTION_TITLES < <(extract_sections_attr_lines "title")
mapfile -t SECTION_TYPES  < <(extract_sections_attr_lines "type")

[[ "${#SECTION_IDS[@]}" -gt 0 ]] || die "No library sections found (parse failed)."

cecho "$GREEN" "Found ${#SECTION_IDS[@]} libraries"
echo

########################################
# Collect locations for each library + display
########################################
LOC_PATH=()            # normalized
LOC_PATH_RAW=()        # raw
LOC_SECTION_ID=()
LOC_SECTION_TITLE=()

cecho "$CYAN" "Libraries and paths:"
echo

for i in "${!SECTION_IDS[@]}"; do
  sid="${SECTION_IDS[$i]}"
  title="${SECTION_TITLES[$i]:-unknown}"
  type="${SECTION_TYPES[$i]:-unknown}"

  # Paths for this section come from the top-level /library/sections XML
  mapfile -t PATHS_RAW < <(
    extract_xpath_attr_lines "$SECTIONS_XML" "/MediaContainer/Directory[$((i+1))]/Location/@path" "path"
  )

  cecho "$BOLD" "Library: $title ($type) [id=$sid]"
  if [[ "${#PATHS_RAW[@]}" -eq 0 ]]; then
    echo "  - (No Location paths found)"
    echo
    continue
  fi

  for p_raw in "${PATHS_RAW[@]}"; do
    p_raw="$(trim "$p_raw")"
    [[ -z "$p_raw" ]] && continue
    p_norm="$(norm_path "$p_raw")"

    LOC_PATH+=("$p_norm")
    LOC_PATH_RAW+=("$p_raw")
    LOC_SECTION_ID+=("$sid")
    LOC_SECTION_TITLE+=("$title")

    if [[ "$p_norm" == "$p_raw" ]]; then
      echo "  - $p_norm"
    else
      echo "  - $p_raw"
      echo "    normalized -> $p_norm"
    fi
  done
  echo
done

if [[ "${#LOC_PATH[@]}" -eq 0 ]]; then
  cecho "$YELLOW" "WARNING: No library location paths were parsed. Scans will treat everything as unaccounted."
  echo
fi

########################################
# Validate filesystem paths exist
########################################
cecho "$CYAN" "Checking configured library paths exist locally..."
missing=0
for i in "${!LOC_PATH[@]}"; do
  if [[ ! -e "${LOC_PATH[$i]}" ]]; then
    ((missing++)) || true
    cecho "$YELLOW" "MISSING: ${LOC_SECTION_TITLE[$i]} → ${LOC_PATH_RAW[$i]} (normalized: ${LOC_PATH[$i]})"
  fi
done

echo
if [[ "$missing" -eq 0 ]]; then
  cecho "$GREEN" "All configured Plex library paths exist"
else
  cecho "$YELLOW" "$missing missing Plex library path(s) detected"
fi

########################################
# Scan roots + exclude tracking (normalized comparison)
########################################
UNACCOUNTED=()

if [[ "${#SCAN_ROOTS[@]}" -gt 0 ]]; then
  echo
  cecho "$CYAN" "Scanning roots for directories not covered by any existing library location..."
  echo "Roots:"
  NORM_SCAN_ROOTS=()
  for r in "${SCAN_ROOTS[@]}"; do
    nr="$(norm_path "$r")"
    NORM_SCAN_ROOTS+=("$nr")
    echo "  - $nr"
  done
  echo

  COVER_PREFIXES=()
  for p in "${LOC_PATH[@]}"; do
    COVER_PREFIXES+=("$(norm_path "${p%/}")")
  done

  echo "Cover prefixes (from Plex library locations): ${#COVER_PREFIXES[@]}"
  printf '  - %s\n' "${COVER_PREFIXES[@]}" | head -n 25
  echo

  for r in "${NORM_SCAN_ROOTS[@]}"; do
    r="$(trim "$r")"
    [[ -z "$r" ]] && continue
    [[ -d "$r" ]] || { cecho "$YELLOW" "Skipping non-directory root: $r"; continue; }

    cecho "$CYAN" "Scanning: $r"
    while IFS= read -r d; do
      d="$(norm_path "${d%/}")"

      # if excluded, skip silently
      if is_excluded "$d"; then
        continue
      fi

      accounted=false
      for prefix in "${COVER_PREFIXES[@]}"; do
        prefix="$(norm_path "${prefix%/}")"
        case "$d" in
          "$prefix" | "$prefix"/*)
            accounted=true
            break
            ;;
        esac
      done

      if [[ "$accounted" == "false" ]]; then
        UNACCOUNTED+=("$d")
      fi
    done < <(LC_ALL=C find "$r" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
  done

  echo
  if [[ "${#UNACCOUNTED[@]}" -eq 0 ]]; then
    cecho "$GREEN" "No unaccounted directories found (excluding do-not-add list)."
  else
    cecho "$YELLOW" "Unaccounted directories (excluding do-not-add list):"
    printf '  - %s\n' "${UNACCOUNTED[@]}"
  fi
fi

########################################
# Interactive exclude prompting (and add-new later)
########################################
if [[ "${#UNACCOUNTED[@]}" -gt 0 ]]; then
  echo
  cecho "$CYAN" "For each unaccounted directory, choose an action:"
  if $ADD_NEW; then
    echo "  [A] Add library (requires --add-new)"
  fi
  echo "  [E] Exclude forever (add to do-not-add list)"
  echo "  [S] Skip once"
  echo

  TO_ADD=()

  for d in "${UNACCOUNTED[@]}"; do
    while true; do
      if $ADD_NEW; then
        if $COLOR_ENABLED; then
          printf "%b" "$(printf '%bAction for %b%s%b (A/E/S): ' "$BWHITE" "$RESET" "$d" "$RESET")"
        else
          printf "Action for '%s' (A/E/S): " "$d"
        fi
      else
        if $COLOR_ENABLED; then
          printf "%b" "$(printf '%bAction for %b%s%b (E/S): ' "$BWHITE" "$RESET" "$d" "$RESET")"
        else
          printf "Action for '%s' (E/S): " "$d"
        fi
      fi
      read -r action
      action="$(echo "$(trim "$action")" | tr '[:upper:]' '[:lower:]')"

      if [[ "$action" == "e" ]]; then
        add_exclude "$d"
        cecho "$YELLOW" "  -> Excluded forever."
        break
      elif [[ "$action" == "s" || -z "$action" ]]; then
        cecho "$YELLOW" "  -> Skipped once."
        break
      elif [[ "$action" == "a" && "$ADD_NEW" == "true" ]]; then
        TO_ADD+=("$d")
        cecho "$GREEN" "  -> Marked to add."
        break
      else
        cecho "$RED" "  Invalid choice."
      fi
    done
  done

  UNACCOUNTED=("${TO_ADD[@]}")
fi

########################################
# Add new libraries (optional) + template reuse
########################################
if $ADD_NEW; then
  [[ "${#UNACCOUNTED[@]}" -gt 0 ]] || { echo; cecho "$YELLOW" "No directories selected to add."; exit 0; }

  echo
  cecho "$CYAN" "Template reuse: choose or reuse an existing library to copy type/agent/scanner/language."
  echo

  USE_SAVED_TEMPLATE=false
  if [[ -n "$TEMPLATE_TYPE" && -n "$TEMPLATE_AGENT" && -n "$TEMPLATE_SCANNER" ]]; then
    cecho "$CYAN" "Using saved template settings:"
    echo "  type:     $TEMPLATE_TYPE"
    echo "  agent:    $TEMPLATE_AGENT"
    echo "  scanner:  $TEMPLATE_SCANNER"
    echo "  language: $TEMPLATE_LANG"
    echo
    if confirm "Use these saved template settings?"; then
      USE_SAVED_TEMPLATE=true
    fi
  fi

  if ! $USE_SAVED_TEMPLATE; then
    cecho "$CYAN" "Choose a template library:"
    for i in "${!SECTION_IDS[@]}"; do
      echo "  $((i+1))) ${SECTION_TITLES[$i]} (${SECTION_TYPES[$i]}) [id=${SECTION_IDS[$i]}]"
    done

    TEMPLATE_IDX=""
    while true; do
      if $COLOR_ENABLED; then
        printf "%b" "$(printf '%bTemplate number%b (1-%d): ' "$BWHITE" "$RESET" "${#SECTION_IDS[@]}")"
      else
        printf "Template number (1-%d): " "${#SECTION_IDS[@]}"
      fi
      read -r TEMPLATE_IDX
      TEMPLATE_IDX="$(trim "$TEMPLATE_IDX")"
      [[ "$TEMPLATE_IDX" =~ ^[0-9]+$ ]] || { cecho "$RED" "Enter a number."; continue; }
      (( TEMPLATE_IDX >= 1 && TEMPLATE_IDX <= ${#SECTION_IDS[@]} )) || { cecho "$RED" "Out of range."; continue; }
      break
    done
    TEMPLATE_IDX=$((TEMPLATE_IDX-1))
    TEMPLATE_ID="${SECTION_IDS[$TEMPLATE_IDX]}"
    TEMPLATE_TITLE="${SECTION_TITLES[$TEMPLATE_IDX]}"

    TEMPLATE_TYPE="$(echo "$SECTIONS_XML" | xmllint --xpath "string(/MediaContainer/Directory[$((TEMPLATE_IDX+1))]/@type)" - 2>/dev/null || true)"
    TEMPLATE_AGENT="$(echo "$SECTIONS_XML" | xmllint --xpath "string(/MediaContainer/Directory[$((TEMPLATE_IDX+1))]/@agent)" - 2>/dev/null || true)"
    TEMPLATE_SCANNER="$(echo "$SECTIONS_XML" | xmllint --xpath "string(/MediaContainer/Directory[$((TEMPLATE_IDX+1))]/@scanner)" - 2>/dev/null || true)"
    TEMPLATE_LANG="$(echo "$SECTIONS_XML" | xmllint --xpath "string(/MediaContainer/Directory[$((TEMPLATE_IDX+1))]/@language)" - 2>/dev/null || true)"
    [[ -n "$TEMPLATE_LANG" ]] || TEMPLATE_LANG="en"

    [[ -n "$TEMPLATE_TYPE" && -n "$TEMPLATE_AGENT" && -n "$TEMPLATE_SCANNER" ]] || die "Could not read template settings."

    echo
    cecho "$CYAN" "Template '$TEMPLATE_TITLE' settings:"
    echo "  type:     $TEMPLATE_TYPE"
    echo "  agent:    $TEMPLATE_AGENT"
    echo "  scanner:  $TEMPLATE_SCANNER"
    echo "  language: $TEMPLATE_LANG"
    echo

    confirm "Use these settings for ALL new libraries?" || die "Aborted."

    save_config
  fi

  echo
  cecho "$CYAN" "Creating new libraries (dry-run: $DRY_RUN)"
  echo

  for d in "${UNACCOUNTED[@]}"; do
    default_name="$(basename "$d")"
    LIB_NAME="$default_name"
    prompt LIB_NAME "Library name for '$d'" "$default_name"

    q_name="$(urlencode "$LIB_NAME")"
    q_type="$(urlencode "$TEMPLATE_TYPE")"
    q_agent="$(urlencode "$TEMPLATE_AGENT")"
    q_scanner="$(urlencode "$TEMPLATE_SCANNER")"
    q_lang="$(urlencode "$TEMPLATE_LANG")"
    q_loc="$(urlencode "$d")"

    create_url="$PLEX_URL/library/sections?name=$q_name&type=$q_type&agent=$q_agent&scanner=$q_scanner&language=$q_lang&location=$q_loc"

    echo "--------------------------------------------------"
    cecho "$CYAN" "New library:"
    echo "  name: $LIB_NAME"
    echo "  dir:  $d"
    echo "  POST: $create_url"

    if $DRY_RUN; then
      cecho "$YELLOW" "DRY-RUN: not creating."
      continue
    fi

    if [[ -z "${PLEX_TOKEN:-}" ]]; then
      cecho "$YELLOW" "Creation may require authentication."
      prompt PLEX_TOKEN "Enter Plex X-Plex-Token (input hidden)" "${PLEX_TOKEN:-}" "true"
      [[ -n "$PLEX_TOKEN" ]] || die "Token cannot be empty."
      save_config
    fi

    resp="$(plex_post "$create_url")" || { cecho "$RED" "POST failed"; continue; }

    if [[ "$STATUS_CODE" == "200" || "$STATUS_CODE" == "201" ]]; then
      cecho "$GREEN" "Created (HTTP $STATUS_CODE)."
    else
      cecho "$YELLOW" "Create returned HTTP $STATUS_CODE"
      echo "$resp" | sed 's/^/  /'
    fi
  done
fi
