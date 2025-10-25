#!/usr/bin/env bash

# depends on: evtest, pactl, timeout, sudo, xdotool(for virt keyboard)
#
# you also really want to have xdotool to make sure that
# evtest has 'gsr-ui virtual keyboard' to register all inputs ()
#

#
# Make sure that you added at the end of visudo: ALL ALL=(ALL) NOPASSWD: /usr/bin/evtest
# it gives ability to use evtest to run as sudo without password (sudo -n)
#
# Also you want to create systemd service that runs as user (not root)
#
# Open: ~/.config/systemd/user/push-to-talk.service
# And put inside with new script location:
# ---------
# [Unit]
# Description=Push to talk
# After=plasma-workspace.target
# Wants=plasma-workspace.target
# StartLimitIntervalSec=0
# StartLimitBurst=0
#
# [Service]
# ExecStart=%h/Scripts/push-to-talk.sh
# Restart=always
# RestartSec=1
#
# [Install]
# WantedBy=graphical-session.target
# ---------
# Then make sure that you've enabled service
# sudo systemctl daemon-reload
# systemctl --user enable --now push-to-talk.service
#

# --- config ---
DEVICE_NAME="gsr-ui virtual keyboard" # desired device name (case-insensitive, substring match) OR full path

# if you want to unmute only certain apps define them like: "!all,app1,app2"
# if you want to mute only certain apps then just define them like: "!app1,!app2" without all at the beginning
declare -A TARGET_RULES=( # rules for keys to watch
  ["KEY_F13"]="!all,input vesktop,gsr-default_input"
  ["KEY_F15"]="!input vesktop"
)
TARGET_MIC_VOLUME="1.0" # float
IDLE_TIMEOUT="10"       # seconds
KEY_DETECTED_TIMEOUT="86400" # seconds / day

# Allow overriding device name/path via CLI: ./script.sh "my device name" OR ./script.sh "/dev/input/event7"
if [[ -n "${1-}" ]]; then
  DEVICE_NAME="$1"
fi

SCRIPT_DIR="$(dirname "$0")"
TMP_FILE="$SCRIPT_DIR/evtest_devices.$$"

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2;
}

get_device_path() {
  # If input is already a valid device path, return it immediately
  if [[ "$DEVICE_NAME" =~ ^/dev/input/event[0-9]+$ ]]; then
    if [[ -c "$DEVICE_NAME" ]]; then
      log "Using provided device path: $DEVICE_NAME"
      echo "$DEVICE_NAME"
      return 0
    else
      log "Error: Device path '$DEVICE_NAME' does not exist"
      return 1
    fi
  fi

  log "Listing input devices via: timeout 1 evtest > $TMP_FILE"

  # Save evtest device list into temp file
  timeout 1 sudo -n evtest >"$TMP_FILE" 2>&1 || true

  if [[ ! -s "$TMP_FILE" ]]; then
    log "evtest produced no output, cannot continue."
    return 1
  fi

  local want_lc="${DEVICE_NAME,,}"
  local found_path="" found_name=""
  local kb_fallback_path="" kb_fallback_name=""

  while IFS= read -r line; do
    [[ "$line" == /dev/input/event*:* ]] || continue

    local path="${line%%:*}"
    local name="${line#*:}"
    name="${name#"${name%%[![:space:]]*}"}"
    local name_lc="${name,,}"

    # Check for exact path match (in case someone passes a path but we still scan)
    if [[ "$path" == "$DEVICE_NAME" ]]; then
      found_path="$path"
      found_name="$name"
      break
    fi

    # Check for name substring match
    if [[ -n "$want_lc" && "$name_lc" == *"$want_lc"* ]]; then
      found_path="$path"
      found_name="$name"
      break
    fi

    # Fallback to first keyboard
    if [[ -z "$kb_fallback_path" && "$name_lc" == *"keyboard"* ]]; then
      kb_fallback_path="$path"
      kb_fallback_name="$name"
    fi
  done <"$TMP_FILE"

  rm -f "$TMP_FILE"

  if [[ -n "$found_path" ]]; then
    log "Matched: \"$found_name\" -> $found_path"
    echo "$found_path"
    return 0
  fi

  if [[ -n "$kb_fallback_path" ]]; then
    log "No exact match. Falling back to first *keyboard*: \"$kb_fallback_name\" -> $kb_fallback_path"
    echo "$kb_fallback_path"
    return 0
  fi

  log "No matching device found (wanted: \"$DEVICE_NAME\"; fallback: *keyboard*)"
  return 1
}

get_default_source() {
  pactl get-default-source
}

unmute_mic() {
  log "Unmuting mic: $1"
  pactl set-source-mute "$1" off
}

mute_mic() {
  log "Muting mic: $1"
  pactl set-source-mute "$1" on
}

set_mic_vol() {
  log "Setting $2 volume for $1 microphone"
  pactl set-source-volume $1 $2
}

get_source_outputs() {
  local def_source=$1 def_index=$2
  local current_index="" source_prop="" name="" binary=""
  while IFS= read -r line; do
    if [[ $line =~ ^Source\ Output\ \#([0-9]+)$ ]]; then
      current_index="${BASH_REMATCH[1]}"
      source_prop=""
      name=""
      binary=""
    elif [[ $line =~ ^[[:space:]]*Source:[[:space:]]*(.*)$ ]]; then
      source_prop="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^[[:space:]]*application.name[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      name="${name%\"}"
      name="${name#\"}"
    elif [[ $line =~ ^[[:space:]]*application.process.binary[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      binary="${BASH_REMATCH[1]}"
      # Remove quotes if they exist around the binary
      binary="${binary//\"/}"
    fi
    if [[ -n $current_index && -n $source_prop && -n $name && -n $binary && ($source_prop == "$def_source" || $source_prop == "$def_index") ]]; then
      echo "$current_index $name $binary"
      current_index=""
    fi
  done < <(pactl list source-outputs)
}


apply_rule() {
  local rule=$1 source=$2 vol=$3
  local source_index
  source_index=$(pactl list short sources | awk -v s="$source" '$2==s {print $1}')
  IFS=',' read -ra items <<< "$rule"

  # Arrays for muted and allowed apps
  declare -A muted_apps=()
  declare -A allowed_apps=()

  log "=== Applying rule: '$rule' to source '$source' (vol: $vol) ==="

  # Parse rule items and populate muted/allowed arrays
  for item in "${items[@]}"; do
    item="$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ $item == !* ]]; then
      # MUTE: anything with ! prefix
      local target="${item#!}"
      if [[ $target == "all" ]]; then
        log "  MUTE: !all (ALL apps muted)"
        muted_apps["all"]=1
      else
        log "  MUTE: !${target}"
        muted_apps["${target,,}"]=1
      fi
    else
      # ALLOW: anything without ! prefix
      if [[ $item == "all" ]]; then
        log "  ALLOW: all (ALL apps allowed)"
        allowed_apps["all"]=1
      else
        log "  ALLOW: ${item}"
        allowed_apps["${item,,}"]=1
      fi
    fi
  done

  # Apply to active apps
  log "  Active apps using microphone:"
  local app_count=0 muted_count=0 allowed_count=0
  while read -r index app_name app_binary; do
    ((app_count++))
    local app_lc="${app_name,,}"
    local binary_lc="${app_binary,,}"
    log "    App #$index: '$app_name' (Binary: $app_binary)"

    local action="" volume=""

    # Check if app should be MUTED
    # Prioritize 'ALLOW' rules first, even over 'all'
    if [[ ${allowed_apps[all]+_} ]] || [[ ${allowed_apps[$app_lc]+_} ]] || [[ ${allowed_apps[$binary_lc]+_} ]]; then
      action="ALLOWED"
      volume="$vol"
      ((allowed_count++))
    # If 'ALLOW' didn't match, mute 'Chromium input' or any other muted app
    elif [[ ${muted_apps[all]+_} ]] || [[ ${muted_apps[$app_lc]+_} ]] || [[ ${muted_apps[$binary_lc]+_} ]]; then
      action="MUTED"
      volume="0.0"
      ((muted_count++))
    # Default: 'ALLOWED' rule for anything unspecified
    else
      action="ALLOWED (default)"
      volume="$vol"
      ((allowed_count++))
    fi

    pactl set-source-output-volume "$index" "$volume"
    log "      -> $action ($volume)"
  done < <(get_source_outputs "$source" "$source_index")

  if [[ $app_count -eq 0 ]]; then
    log "  No active apps using microphone"
  else
    log "  Summary: $app_count apps | $allowed_count allowed ($vol) | $muted_count muted (0.0)"
  fi
  log "=== Rule applied ==="
}

reset_all_outputs() {
  local source=$1 vol=$2
  local source_index
  source_index=$(pactl list short sources | awk -v s="$source" '$2==s {print $1}')
  log "=== Resetting ALL outputs to $vol ==="
  local count=0
  while read -r index app_name; do
    ((count++))
    log "  Reset #$index '$app_name' -> $vol"
    pactl set-source-output-volume "$index" "$vol"
  done < <(get_source_outputs "$source" "$source_index")
  log "=== Reset complete ($count apps) ==="
}

# Global cleanup function
cleanup() {
  local signal="$1"
  log "Received signal $signal - cleaning up..."

  # Mute the current default source
  SOURCE="$(get_default_source 2>/dev/null)" || true
  if [[ -n "$SOURCE" ]]; then
    mute_mic "$SOURCE"
    log "Mic muted"
  fi

  # Clean up temp file
  rm -f "$TMP_FILE"
  log "Temp file cleaned up"

  # Exit with appropriate status
  if [[ "$signal" == "EXIT" ]]; then
    exit 0
  else
    exit 130  # SIGINT exit code
  fi
}

# Set up trap for clean Ctrl+C handling
trap 'cleanup INT' SIGINT
trap 'cleanup TERM' SIGTERM
trap 'cleanup EXIT' EXIT

# Start muted for safety
SOURCE="$(get_default_source)"
log "Default source: $SOURCE"
mute_mic "$SOURCE"
log "Script started - Press Ctrl+C to stop and mute mic"

while true; do
  DEVICE_PATH="$(get_device_path)"
  if [[ -z "$DEVICE_PATH" ]]; then
    log "Error: Could not find device (wanted: \"$DEVICE_NAME\"; fallback: *keyboard*)"
    sleep 2
    continue
  fi
  log "Listening for keys from $DEVICE_PATH (timeout: ${IDLE_TIMEOUT}s)"

  # Use timeout with proper signal forwarding for clean Ctrl+C handling
  timeout --foreground "$IDLE_TIMEOUT" sudo -n evtest "$DEVICE_PATH" | while read -r line; do
    # Skip lines that aren't key events
    [[ "$line" == *"EV_KEY"* ]] || continue
    [[ "$line" == *"value 0"* || "$line" == *"value 1"* ]] || continue

    # Extract key name
    KEY_NAME=$(echo "$line" | grep -oP '\(KEY_[A-Z0-9_]+\)')
    KEY_NAME="${KEY_NAME//[\(\)]/}"

    # Check if key is in target list
    if [[ ${TARGET_RULES[$KEY_NAME]+_} ]]; then

      KEY_VALUE=$(echo "$line" | grep -oP 'value \K[0-9]+')
      SOURCE=$(get_default_source)

      RULE="${TARGET_RULES[$KEY_NAME]}"
      if [[ "$KEY_VALUE" == "1" ]]; then
        log "KEY $KEY_NAME pressed - Unmuting + applying rule: $RULE"
        $IDLE_TIMEOUT="$KEY_DETECTED_TIMEOUT"

        apply_rule "$RULE" "$SOURCE" "$TARGET_MIC_VOLUME"

        set_mic_vol "$SOURCE" "$TARGET_MIC_VOLUME"
        unmute_mic "$SOURCE"
      elif [[ "$KEY_VALUE" == "0" ]]; then
        log "KEY $KEY_NAME released - Muting + resetting all outputs"
        mute_mic "$SOURCE"

        reset_all_outputs "$SOURCE" "$TARGET_MIC_VOLUME"
      fi
    fi
  done || true  # Ignore timeout exit code
done
