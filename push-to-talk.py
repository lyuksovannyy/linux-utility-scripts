import evdev
import subprocess
import atexit
import argparse
import os
import getpass
from typing import List, Dict, Optional, Tuple

#
# you can use --help arg to get additional info
# for easier setup process
#

DEVICE_NAME = "gsr-ui virtual keyboard" # you don't need to modify this one if you installed xdotool
TARGET_MIC_VOLUME = "1.0"

BINDS: Dict[str, List[str]] = {
    "f13": ["!all", "vesktop", "gpu-screen-recorder"],
    "f15": ["!vesktop"],
    "f13 f15": ["all"],
}

ALL_KEYS = set()
for k in BINDS:
    for sk in k.split():
        ALL_KEYS.add(sk)

ACTIVE_KEYS = set()

def run(*args) -> str:
    """Run a command, return stdout (stripped). Errors are printged."""
    try:
        cp = subprocess.run(args, capture_output=True, text=True, check=True)
        return cp.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {' '.join(args)} - {e}")
        return ""

def get_default_source() -> str:
    return run("pactl", "get-default-source")

def toggle_mic(src: str, state: bool):
    print(f"{'Unmuting' if state else 'Muting'} mic: {src}")
    run("pactl", "set-source-mute", src, "0" if state else "1")

def set_source_volume(src: str, volume: str):
    print(f"Setting source volume for {src} to {volume}")
    run("pactl", "set-source-volume", src, volume)

def get_app_sources() -> List[Tuple[str, str, str]]:
    output = run("pactl", "list", "source-outputs")
    if not output:
        return []

    sources = output.split("Source Output")
    app_sources: List[Tuple[str, str, str]] = []

    for source in sources:
        index: Optional[str] = None
        name: Optional[str] = None
        binary: Optional[str] = None
        for line in source.splitlines():
            line = line.strip()

            if line.startswith("object.serial"):
                index = line.split(" = ")[1].replace('"', '').strip()
            elif line.startswith("application.name"):
                name = line.split(" = ")[1].replace('"', '').strip()
            elif line.startswith("application.process.binary"):
                binary = line.split(" = ")[1].replace('"', '').strip()

        binary = binary or "unknown*"
        if index is None or name is None:
            continue

        app_sources.append((index, name, binary))

    return app_sources

def apply_rules(rules: List[str], source: str, volume: str):
    print(f"=== Applying rules: {rules} to source '{source}' (vol: {volume}) ===")

    muted_apps: Dict[str, bool] = {}
    allowed_apps: Dict[str, bool] = {}

    for item in rules:
        item = item.strip()
        if item.startswith("!"):
            target = item[1:].lower()
            muted_apps[target] = True
            print(f"  MUTE: {target}")
        else:
            target = item.lower()
            allowed_apps[target] = True
            print(f"  ALLOW: {target}")

    app_sources = get_app_sources()
    if not app_sources:
        print("  No active apps using microphone")
        print("=== Rule applied ===")
        return

    app_count = 0
    muted_count = 0
    allowed_count = 0
    for index, app_name, app_binary in app_sources:
        app_count += 1
        app_lc = app_name.lower()
        binary_lc = app_binary.lower()
        print(f"    App #{index}: '{app_name}' (Binary: {app_binary})")

        if "all" in allowed_apps or app_lc in allowed_apps or binary_lc in allowed_apps:
            vol = volume
            action = "ALLOWED"
            allowed_count += 1
        elif "all" in muted_apps or app_lc in muted_apps or binary_lc in muted_apps:
            vol = "0.0"
            action = "MUTED"
            muted_count += 1
        else:
            vol = volume
            action = "ALLOWED (default)"
            allowed_count += 1

        run("pactl", "set-source-output-volume", index, vol)
        print(f"      -> {action} ({vol})")

    print(f"  Summary: {app_count} apps | {allowed_count} allowed ({volume}) | {muted_count} muted (0.0)")
    print("=== Rule applied ===")

def cleanup():
    source = get_default_source()
    if source:
        toggle_mic(source, False)
        print("Mic muted on exit")

def find_device_path() -> Optional[str]:
    want_lc = DEVICE_NAME.lower()
    found_path = None
    found_name = None
    kb_fallback_path = None
    kb_fallback_name = None

    for path in evdev.list_devices():
        print(path)
        dev = evdev.InputDevice(path)
        name_lc = dev.name.lower()

        if want_lc in name_lc:
            found_path = path
            found_name = dev.name
            break

        if not kb_fallback_path and "keyboard" in name_lc:
            kb_fallback_path = path
            kb_fallback_name = dev.name

    if found_path:
        print(f"Matched: '{found_name}' -> {found_path}")
        return found_path

    if kb_fallback_path:
        print(f"No exact match. Falling back to first *keyboard*: '{kb_fallback_name}' -> {kb_fallback_path}")
        return kb_fallback_path

    print(f"No matching device found (wanted: '{DEVICE_NAME}'; fallback: *keyboard*)")
    return None

parser = argparse.ArgumentParser(description="Push to talk script")
parser.add_argument('--install', action='store_true', help='Install required packages (xdotool, python-evdev)')
parser.add_argument('--enable-service', action='store_true', help='Enable and start the systemd user service')
parser.add_argument('--disable-service', action='store_true', help='Disable and stop the systemd user service')

args = parser.parse_args()

handled = False

if args.install:
    print("Installing required packages...")
    subprocess.run(['sudo', 'pacman', '-S', '--needed', 'xdotool', 'python-evdev'])
    current_user = getpass.getuser()
    print(f"\nTo allow access to input devices without root, run:")
    print(f"sudo usermod -aG input {current_user}")
    print("Then log out and log back in for changes to take effect.")
    handled = True

if args.enable_service:
    print("Setting up systemd user service...")
    home = os.environ['HOME']
    script_path = os.path.abspath(__file__)
    service_dir = os.path.join(home, '.config', 'systemd', 'user')
    os.makedirs(service_dir, exist_ok=True)
    service_path = os.path.join(service_dir, 'push-to-talk.service')
    with open(service_path, 'w') as f:
        f.write(f"""[Unit]
Description=Push to talk
After=graphical-session.target
Wants=graphical-session.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
ExecStart=/usr/bin/python3 {script_path}
Restart=always
RestartSec=1

[Install]
WantedBy=graphical-session.target
""")
    run("systemctl", "--user", "daemon-reload")
    run("systemctl", "--user", "enable", "--now", "push-to-talk.service")
    print("Service enabled and started.")
    handled = True

if args.disable_service:
    print("Disabling systemd user service...")
    run("systemctl", "--user", "disable", "--now", "push-to-talk.service")
    print("Service disabled and stopped.")
    handled = True

if handled:
    exit(0)

# Main script execution
if __name__ == "__main__":
    atexit.register(cleanup)

    source = get_default_source()
    print(f"Default source: {source}")
    toggle_mic(source, False)
    print("Script started - Mic muted initially")

    device_path = find_device_path()
    if not device_path:
        print("Error: Could not find device")
        exit(1)

    dev = evdev.InputDevice(device_path)
    print(f"Listening for keys from {device_path}")

    for event in dev.read_loop():
        if event.type != evdev.ecodes.EV_KEY or event.value == 2:
            continue

        key_name = evdev.ecodes.KEY.get(event.code)
        if not key_name:
            continue

        key = str(key_name).removeprefix("KEY_").lower()
        if key not in ALL_KEYS:
            continue

        source = get_default_source()

        if event.value == 1:  # Press
            ACTIVE_KEYS.add(key)
            print(f"KEY {key.upper()} pressed")
        elif event.value == 0:  # Release
            if key in ACTIVE_KEYS:
                ACTIVE_KEYS.remove(key)
            print(f"KEY {key.upper()} released")

        if not ACTIVE_KEYS:
            apply_rules(["all"], source, TARGET_MIC_VOLUME)
            toggle_mic(source, False)
            continue

        rules_key = " ".join(sorted(ACTIVE_KEYS))
        rules = BINDS.get(rules_key)
        if rules:
            set_source_volume(source, TARGET_MIC_VOLUME)
            apply_rules(rules, source, TARGET_MIC_VOLUME)
            toggle_mic(source, True)
