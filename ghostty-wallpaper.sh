#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly MANAGED_COMMENT="# Managed by ghostty-wallpaper.sh"
readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
readonly DEFAULT_XDG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
readonly DEFAULT_XDG_CONFIG_FILE="${DEFAULT_XDG_CONFIG_DIR}/config"
readonly DEFAULT_MACOS_CONFIG_FILE="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
readonly DEFAULT_MANAGED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty-wallpapers"
readonly DEFAULT_OVERLAY_FILE="${DEFAULT_MANAGED_DIR}/wallpaper.conf"
readonly DEFAULT_STATE_FILE="${DEFAULT_MANAGED_DIR}/state"
readonly DEFAULT_LAUNCHD_LABEL="net.tiibun.ghostty-wallpaper"
readonly DEFAULT_LAUNCHD_INTERVAL="900"
readonly DEFAULT_LAUNCHD_LOG_FILE="$HOME/Library/Logs/ghostty-wallpaper.log"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--wallpaper-dir DIR] [options]

Rotate the Ghostty background image by updating a managed config overlay.

Options:
  --wallpaper-dir DIR       Directory containing wallpaper images (required on first run, or if not previously saved)
  --mode MODE              Rotation mode: sequential or random (default: sequential)
  --config-file PATH       Ghostty config file to update
  --overlay-file PATH      Managed overlay file to write (default: ${DEFAULT_OVERLAY_FILE})
  --state-file PATH        State file used to remember the last wallpaper (default: ${DEFAULT_STATE_FILE})
  --reload-method METHOD   How to apply changes when Ghostty is running: sigusr2, applescript, or none (default: sigusr2)
  --print-launchd-plist    Print a launchd plist to stdout and exit
  --launchd-label LABEL    Label to use in the generated plist (default: ${DEFAULT_LAUNCHD_LABEL})
  --launchd-interval SEC   StartInterval to use in the generated plist (default: ${DEFAULT_LAUNCHD_INTERVAL})
  --launchd-log-file PATH  Log file path to use in the generated plist (default: ${DEFAULT_LAUNCHD_LOG_FILE})
  --print-selection        Print the selected wallpaper path to stdout
  --help                   Show this help text
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

escape_config_value() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

xml_escape() {
  local value="$1"
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\"/&quot;}
  value=${value//\'/&apos;}
  printf '%s' "$value"
}

validate_mode() {
  case "${mode}" in
    sequential|random)
      ;;
    *)
      die "unsupported mode: ${mode}"
      ;;
  esac
}

validate_reload_method() {
  case "${reload_method}" in
    sigusr2|applescript|none)
      ;;
    *)
      die "unsupported reload method: ${reload_method}"
      ;;
  esac
}

validate_launchd_interval() {
  [[ "${launchd_interval}" =~ ^[0-9]+$ ]] || die "--launchd-interval must be a non-negative integer"
}

print_launchd_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$(xml_escape "${launchd_label}")</string>

    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$(xml_escape "${SCRIPT_PATH}")</string>
      <string>--wallpaper-dir</string>
      <string>$(xml_escape "${wallpaper_dir}")</string>
      <string>--mode</string>
      <string>$(xml_escape "${mode}")</string>
EOF

  if [[ -n "${config_file}" ]]; then
    cat <<EOF
      <string>--config-file</string>
      <string>$(xml_escape "${config_file}")</string>
EOF
  fi

  if [[ "${overlay_file}" != "${DEFAULT_OVERLAY_FILE}" ]]; then
    cat <<EOF
      <string>--overlay-file</string>
      <string>$(xml_escape "${overlay_file}")</string>
EOF
  fi

  if [[ "${state_file}" != "${DEFAULT_STATE_FILE}" ]]; then
    cat <<EOF
      <string>--state-file</string>
      <string>$(xml_escape "${state_file}")</string>
EOF
  fi

  cat <<EOF
      <string>--reload-method</string>
      <string>$(xml_escape "${reload_method}")</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>${launchd_interval}</integer>

    <key>StandardOutPath</key>
    <string>$(xml_escape "${launchd_log_file}")</string>

    <key>StandardErrorPath</key>
    <string>$(xml_escape "${launchd_log_file}")</string>
  </dict>
</plist>
EOF
}

select_config_file() {
  if [[ -n "${config_file}" ]]; then
    printf '%s\n' "${config_file}"
  elif [[ -f "${DEFAULT_MACOS_CONFIG_FILE}" ]]; then
    printf '%s\n' "${DEFAULT_MACOS_CONFIG_FILE}"
  elif [[ -f "${DEFAULT_XDG_CONFIG_FILE}" ]]; then
    printf '%s\n' "${DEFAULT_XDG_CONFIG_FILE}"
  else
    printf '%s\n' "${DEFAULT_XDG_CONFIG_FILE}"
  fi
}

ensure_include_block() {
  local target_config="$1"
  local include_line="$2"
  local config_dir
  local tmp_file

  config_dir="$(dirname "${target_config}")"
  mkdir -p "${config_dir}"
  [[ -f "${target_config}" ]] || : > "${target_config}"

  tmp_file="$(mktemp)"
  awk -v marker="${MANAGED_COMMENT}" '
    $0 == marker {
      skip = 1
      next
    }
    skip == 1 {
      skip = 0
      next
    }
    { print }
  ' "${target_config}" > "${tmp_file}"
  mv "${tmp_file}" "${target_config}"

  if [[ -s "${target_config}" ]] && [[ -n "$(tail -c 1 "${target_config}")" ]]; then
    printf '\n' >> "${target_config}"
  fi

  {
    printf '%s\n' "${MANAGED_COMMENT}"
    printf '%s\n' "${include_line}"
  } >> "${target_config}"
}

load_wallpapers() {
  local dir="$1"
  local path

  [[ -d "${dir}" ]] || die "wallpaper directory does not exist: ${dir}"

  wallpapers=()
  while IFS= read -r path; do
    [[ -n "${path}" ]] && wallpapers+=("${path}")
  done < <(
    find "${dir}" -type f \( \
      -iname '*.png' -o \
      -iname '*.jpg' -o \
      -iname '*.jpeg' -o \
      -iname '*.webp' -o \
      -iname '*.gif' -o \
      -iname '*.bmp' \
    \) | LC_ALL=C sort
  )

  [[ "${#wallpapers[@]}" -gt 0 ]] || die "no supported images found in ${dir}"
}

read_state() {
  if [[ ! -f "${state_file}" ]]; then
    return
  fi

  local last_index
  local saved_wallpaper_dir
  
  last_index="$(awk -F= '$1 == "last_index" { print $2 }' "${state_file}" 2>/dev/null | tail -n 1)"
  saved_wallpaper_dir="$(awk -F= '$1 == "wallpaper_dir" { print substr($0, index($0,$2)) }' "${state_file}" 2>/dev/null | tail -n 1)"
  
  if [[ "${last_index}" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "${last_index}"
  else
    printf '%s\n' "-1"
  fi
}

read_saved_wallpaper_dir() {
  if [[ ! -f "${state_file}" ]]; then
    return
  fi

  awk -F= '$1 == "wallpaper_dir" { print substr($0, index($0,$2)) }' "${state_file}" 2>/dev/null | tail -n 1
}

write_state() {
  local selected_index="$1"
  local selected_path="$2"

  mkdir -p "$(dirname "${state_file}")"
  cat > "${state_file}" <<EOF
wallpaper_dir=${wallpaper_dir}
last_index=${selected_index}
last_wallpaper=${selected_path}
EOF
}

warn_if_orientation_metadata_present() {
  local image_path="$1"
  local orientation

  if ! orientation="$(sips -g orientation "${image_path}" 2>/dev/null | awk -F': ' '/orientation:/ { print $2; exit }')"; then
    return
  fi

  case "${orientation}" in
    ""|"<nil>"|1)
      return
      ;;
  esac

  printf 'Warning: selected image has EXIF orientation=%s; Ghostty may display it sideways. Re-save or export the image so the pixels are already upright.\n' "${orientation}" >&2
}

pick_wallpaper() {
  local count="${#wallpapers[@]}"
  local last_index
  local next_index
  local candidate

  last_index="$(read_state)"

  case "${mode}" in
    sequential)
      next_index=$(( (last_index + 1 + count) % count ))
      ;;
    random)
      if [[ "${count}" -eq 1 ]]; then
        next_index=0
      else
        next_index=$(( RANDOM % count ))
        if [[ "${next_index}" -eq "${last_index}" ]]; then
          candidate=$(( (next_index + 1) % count ))
          next_index="${candidate}"
        fi
      fi
      ;;
  esac

  selected_index="${next_index}"
  selected_wallpaper="${wallpapers[${selected_index}]}"
}

write_overlay() {
  local overlay_dir
  overlay_dir="$(dirname "${overlay_file}")"
  mkdir -p "${overlay_dir}"

  cat > "${overlay_file}" <<EOF
${MANAGED_COMMENT}
background-image = $(escape_config_value "${selected_wallpaper}")
EOF
}

ghostty_pids() {
  ps -axo pid=,ucomm= | awk '$2 == "ghostty" { print $1 }'
}

reload_ghostty() {
  local ghostty_pid

  case "${reload_method}" in
    none)
      return
      ;;
    sigusr2)
      if ! ghostty_pids >/dev/null; then
        return
      fi

      while IFS= read -r ghostty_pid; do
        [[ -n "${ghostty_pid}" ]] || continue
        kill -USR2 "${ghostty_pid}"
      done < <(ghostty_pids)
      ;;
    applescript)
      if ! ghostty_pids >/dev/null; then
        return
      fi

      osascript <<'APPLESCRIPT'
tell application "Ghostty" to activate
tell application "System Events"
  tell process "Ghostty"
    click menu item "Reload Configuration" of menu "Ghostty" of menu bar item "Ghostty" of menu bar 1
  end tell
end tell
APPLESCRIPT
      ;;
  esac
}

wallpaper_dir=""
mode="sequential"
config_file=""
overlay_file="${DEFAULT_OVERLAY_FILE}"
state_file="${DEFAULT_STATE_FILE}"
reload_method="sigusr2"
print_launchd_plist_mode=0
launchd_label="${DEFAULT_LAUNCHD_LABEL}"
launchd_interval="${DEFAULT_LAUNCHD_INTERVAL}"
launchd_log_file="${DEFAULT_LAUNCHD_LOG_FILE}"
print_selection=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wallpaper-dir)
      [[ $# -ge 2 ]] || die "--wallpaper-dir requires a value"
      wallpaper_dir="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value"
      mode="$2"
      shift 2
      ;;
    --config-file)
      [[ $# -ge 2 ]] || die "--config-file requires a value"
      config_file="$2"
      shift 2
      ;;
    --overlay-file)
      [[ $# -ge 2 ]] || die "--overlay-file requires a value"
      overlay_file="$2"
      shift 2
      ;;
    --state-file)
      [[ $# -ge 2 ]] || die "--state-file requires a value"
      state_file="$2"
      shift 2
      ;;
    --reload-method)
      [[ $# -ge 2 ]] || die "--reload-method requires a value"
      reload_method="$2"
      shift 2
      ;;
    --print-launchd-plist)
      print_launchd_plist_mode=1
      shift
      ;;
    --launchd-label)
      [[ $# -ge 2 ]] || die "--launchd-label requires a value"
      launchd_label="$2"
      shift 2
      ;;
    --launchd-interval)
      [[ $# -ge 2 ]] || die "--launchd-interval requires a value"
      launchd_interval="$2"
      shift 2
      ;;
    --launchd-log-file)
      [[ $# -ge 2 ]] || die "--launchd-log-file requires a value"
      launchd_log_file="$2"
      shift 2
      ;;
    --print-selection)
      print_selection=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "${wallpaper_dir}" ]]; then
  wallpaper_dir="$(read_saved_wallpaper_dir)"
  [[ -n "${wallpaper_dir}" ]] || die "--wallpaper-dir is required or no saved wallpaper directory found"
fi

validate_mode
validate_reload_method
validate_launchd_interval

if [[ "${print_launchd_plist_mode}" -eq 1 ]]; then
  print_launchd_plist
  exit 0
fi

config_file="$(select_config_file)"
include_line="config-file = $(escape_config_value "${overlay_file}")"

declare -a wallpapers
selected_index=0
selected_wallpaper=""

load_wallpapers "${wallpaper_dir}"
pick_wallpaper
warn_if_orientation_metadata_present "${selected_wallpaper}"
ensure_include_block "${config_file}" "${include_line}"
write_overlay
write_state "${selected_index}" "${selected_wallpaper}"
reload_ghostty

if [[ "${print_selection}" -eq 1 ]]; then
  printf '%s\n' "${selected_wallpaper}"
fi
