#!/usr/bin/env bash
# Set up the Goodix 27c6:55b4 fingerprint reader on supported Fedora/Ubuntu.
# Installs a matching libfprint build, checks/provisions the sensor if needed,
# enrolls and verifies a finger, and offers an optional PAM login override.
#
# Run from a terminal: ./setup-goodix55b4.sh
# The script asks before replacing libfprint, changing the sensor, or editing PAM.

set -Eeuo pipefail

readonly RELEASE_BASE="https://github.com/TheWeirdDev/libfprint-goodix55b4-milan/releases/latest/download"
readonly FLASH_REPO="https://github.com/mpi3d/goodix-fp-dump.git"
readonly FLASH_COMMIT="cc43bb3b3154a0bccc0412ae024013c7e1923139"
readonly TARGET_FIRMWARE="GF3268_RTSEC_APP_10041"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer </dev/tty
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

if (( EUID != 0 )); then
    exec sudo -- bash "$0" "$@"
fi

if [[ ! -r /etc/os-release ]]; then
    die "Cannot identify this Linux distribution."
fi
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    fedora)
        DISTRO="Fedora ${VERSION_ID}"
        ASSET_SUFFIX=".fc${VERSION_ID}.x86_64.rpm"
        PM="dnf"
        ;;
    ubuntu)
        DISTRO="Ubuntu ${VERSION_ID}"
        ASSET_SUFFIX="_ubuntu${VERSION_ID}_amd64.deb"
        PM="apt"
        ;;
    *)
        die "This script supports Fedora and Ubuntu; detected ${PRETTY_NAME:-unknown}."
        ;;
esac

[[ "$(uname -m)" == "x86_64" ]] || die "The published driver packages support x86_64 only."

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    read -r -p "Linux username to enroll: " TARGET_USER </dev/tty
fi
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."

if ! command -v curl >/dev/null 2>&1; then
    die "curl is required to download the verified driver package."
fi
if ! command -v git >/dev/null 2>&1; then
    die "git is required to fetch the pinned provisioning utility."
fi

# Detect the fingerprint sensor without depending on lsusb/usbutils.
FOUND_SENSOR=0
for usbdev in /sys/bus/usb/devices/*; do
    [[ -r "$usbdev/idVendor" && -r "$usbdev/idProduct" ]] || continue
    if [[ "$(<"$usbdev/idVendor")" == 27c6 && "$(<"$usbdev/idProduct")" == 55b4 ]]; then
        FOUND_SENSOR=1
        break
    fi
done
(( FOUND_SENSOR == 1 )) || die "Goodix 27c6:55b4 was not found on USB."

say "Detected $DISTRO, x86_64, and Goodix 27c6:55b4."
say "The driver package replaces the distribution's libfprint package."
say "The sensor may need firmware 10041 and a zero PSK; this breaks Windows Hello pairing on this reader."
say "The pinned community flashing utility warns that flashing can damage the sensor."
say "If you dual-boot Windows, its fingerprint driver may re-provision the reader; disable that driver before using this sensor in Windows again."
confirm "Continue with the Goodix driver setup?" || exit 0

case "$PM" in
    dnf)
        dnf install -y ca-certificates curl git openssl python3 python3-pip python3-devel gcc \
            fprintd fprintd-pam
        ;;
    apt)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates curl git openssl python3 python3-pip python3-venv python3-dev \
            build-essential fprintd libpam-fprintd
        ;;
esac

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/goodix55b4-setup.XXXXXX")"
FPRINTD_STOPPED=0
cleanup() {
    if (( FPRINTD_STOPPED )); then
        systemctl start fprintd >/dev/null 2>&1 || true
    fi
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
}
trap cleanup EXIT

say "Fetching the latest release manifest and matching package..."
curl -fsSL "$RELEASE_BASE/SHA256SUMS" -o "$WORKDIR/SHA256SUMS" || \
    die "Could not download the driver's SHA256SUMS manifest."
ASSET_LINE="$(awk -v suffix="$ASSET_SUFFIX" 'substr($2, length($2)-length(suffix)+1) == suffix { print; exit }' "$WORKDIR/SHA256SUMS")"
[[ -n "$ASSET_LINE" ]] || die "No matching package exists for $DISTRO in the latest release."
read -r ASSET_HASH ASSET_PATH <<< "$ASSET_LINE"
ASSET_NAME="${ASSET_PATH#./}"
curl -fL "$RELEASE_BASE/$ASSET_NAME" -o "$WORKDIR/$ASSET_NAME" || \
    die "Could not download $ASSET_NAME."
(cd "$WORKDIR" && printf '%s  %s\n' "$ASSET_HASH" "$ASSET_NAME" | sha256sum -c -) || \
    die "Driver package checksum did not match the release manifest."

say "Installing the verified driver package. This replaces stock libfprint."
case "$PM" in
    dnf) dnf install -y --allowerasing "$WORKDIR/$ASSET_NAME" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$WORKDIR/$ASSET_NAME" ;;
esac

say "Fetching the pinned Goodix firmware/PSK utility (commit $FLASH_COMMIT)..."
FLASHDIR="$WORKDIR/goodix-fp-dump"
git clone --recurse-submodules "$FLASH_REPO" "$FLASHDIR"
git -C "$FLASHDIR" checkout --detach "$FLASH_COMMIT"
git -C "$FLASHDIR" submodule update --init --recursive
python3 -m venv "$WORKDIR/venv"
"$WORKDIR/venv/bin/pip" install --disable-pip-version-check \
    pyusb==1.3.1 crcmod==1.7 python-periphery==2.5.0 spidev==3.8 \
    pycryptodome==4.4.0 crccheck==1.3.1

# Read only firmware/PSK probe. It does not capture a fingerprint or write the
# key/firmware. The flash helper is separately gated below.
cat > "$FLASHDIR/status_55b4.py" <<'PY'
import driver_55x4

device = driver_55x4.init_device(0x55B4)
try:
    firmware = device.firmware_version()
    zero_psk = driver_55x4.check_psk(device)
    iap = device.get_iap_version(25)
    print(f"STATUS_FIRMWARE={firmware}")
    print(f"STATUS_ZERO_PSK={'yes' if zero_psk else 'no'}")
    print(f"STATUS_IAP={iap}")
finally:
    device.disconnect()
PY

# Keep the flash helper's safety checks and random confirmation, but skip its
# optional post-flash fingerprint image capture (fingerprint.pgm).
cat > "$FLASHDIR/provision_55b4_no_capture.py" <<'PY'
import driver_55x4

def skip_capture(_device):
    print("Firmware and zero-PSK verified; skipping fingerprint image capture.")

driver_55x4.run_driver = skip_capture
driver_55x4.main(0x55B4)
PY

systemctl stop fprintd || true
FPRINTD_STOPPED=1
STATUS_OUTPUT="$(cd "$FLASHDIR" && "$WORKDIR/venv/bin/python" status_55b4.py)" || \
    die "Could not read sensor firmware/PSK status."
printf '%s\n' "$STATUS_OUTPUT"
FIRMWARE="$(sed -n 's/^STATUS_FIRMWARE=//p' <<< "$STATUS_OUTPUT" | tail -n 1)"
ZERO_PSK="$(sed -n 's/^STATUS_ZERO_PSK=//p' <<< "$STATUS_OUTPUT" | tail -n 1)"
IAP="$(sed -n 's/^STATUS_IAP=//p' <<< "$STATUS_OUTPUT" | tail -n 1)"
[[ -n "$FIRMWARE" && -n "$ZERO_PSK" ]] || die "The sensor did not return a readable status."

if [[ "$FIRMWARE" != "$TARGET_FIRMWARE" || "$ZERO_PSK" != yes ]]; then
    say ""
    say "Current sensor state: firmware=$FIRMWARE, zero_psk=$ZERO_PSK, IAP=$IAP"
    say "The next step may erase/flash firmware and will replace the Windows pairing key."
    say "The community utility does not back up the old firmware or pairing key."
    read -r -p "Type FLASH-AND-REPROVISION to continue: " REPLY </dev/tty
    [[ "$REPLY" == FLASH-AND-REPROVISION ]] || {
        say "Stopped before changing sensor firmware or PSK."
        exit 0
    }
    (cd "$FLASHDIR" && "$WORKDIR/venv/bin/python" provision_55b4_no_capture.py)

    STATUS_OUTPUT="$(cd "$FLASHDIR" && "$WORKDIR/venv/bin/python" status_55b4.py)" || \
        die "Provisioning finished, but the follow-up status probe failed."
    printf '%s\n' "$STATUS_OUTPUT"
    FIRMWARE="$(sed -n 's/^STATUS_FIRMWARE=//p' <<< "$STATUS_OUTPUT" | tail -n 1)"
    ZERO_PSK="$(sed -n 's/^STATUS_ZERO_PSK=//p' <<< "$STATUS_OUTPUT" | tail -n 1)"
    [[ "$FIRMWARE" == "$TARGET_FIRMWARE" && "$ZERO_PSK" == yes ]] || \
        die "Sensor is not at the expected firmware/PSK state; stopping before enrollment."
else
    say "Sensor already has firmware 10041 and the zero PSK; no sensor write is needed."
fi

systemctl start fprintd
FPRINTD_STOPPED=0

ENROLLED="$(fprintd-list "$TARGET_USER" 2>&1 || true)"
if grep -q "right-index-finger" <<< "$ENROLLED"; then
    say "A right-index fingerprint is already enrolled for $TARGET_USER."
    if confirm "Replace/re-enroll that print now?"; then
        fprintd-delete -f right-index-finger "$TARGET_USER"
        fprintd-enroll -f right-index-finger "$TARGET_USER"
    fi
else
    say "Enroll the same finger with firm, flat presses; lift between prompts."
    fprintd-enroll -f right-index-finger "$TARGET_USER"
fi

if ! confirm "Run a fingerprint verification scan now?"; then
    say "Skipping verification, so login-screen fingerprint authentication was not changed."
    exit 0
fi
if ! fprintd-verify -f right-index-finger "$TARGET_USER"; then
    if confirm "Verification missed. Delete and re-enroll the right index finger, then retry?"; then
        fprintd-delete -f right-index-finger "$TARGET_USER"
        fprintd-enroll -f right-index-finger "$TARGET_USER"
        fprintd-verify -f right-index-finger "$TARGET_USER" || \
            die "Verification still did not match. Login PAM was left unchanged."
    else
        die "Verification did not match. Login PAM was left unchanged."
    fi
fi

# Add a reversible display-manager PAM entry without editing authselect's
# generated files. It is sufficient on success; failure falls through to the
# existing password stack.
cat > "$WORKDIR/enable-login-pam.py" <<'PY'
import os
import re
import shutil
import sys
from pathlib import Path

service = sys.argv[1]
etc = Path("/etc/pam.d")
local = etc / service
vendor_candidates = [Path("/usr/lib/pam.d") / service,
                     Path("/usr/lib64/pam.d") / service]

if local.exists():
    source_text = local.read_text()
    source_path = local
    backup = etc / (service + ".before-goodix55b4")
    if not backup.exists():
        shutil.copy2(local, backup)
    created_local = False
else:
    source_path = next((p for p in vendor_candidates if p.is_file()), None)
    if source_path is None:
        raise SystemExit(f"No PAM service file found for {service}")
    source_text = source_path.read_text()
    created_local = True

if re.search(r"^\s*auth\s+.*\bpam_fprintd\.so\b", source_text, re.M):
    print(f"{service} already has pam_fprintd; no PAM change needed.")
    raise SystemExit(0)

def service_path(name):
    for base in (etc, Path("/usr/lib/pam.d"), Path("/usr/lib64/pam.d")):
        candidate = base / name
        if candidate.is_file():
            return candidate
    return None

def chain_has_fprint(path, seen=None):
    seen = set() if seen is None else seen
    path = path.resolve()
    if path in seen:
        return False
    seen.add(path)
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return False
    for line in lines:
        clean = line.split("#", 1)[0].strip()
        if re.match(r"^auth\s+.*\bpam_fprintd\.so\b", clean):
            return True
        match = re.match(r"^auth\s+(?:include|substack)\s+([\w.-]+)", clean)
        if match:
            included = service_path(match.group(1))
            if included and chain_has_fprint(included, seen):
                return True
        match = re.match(r"^@include\s+([\w.-]+)", clean)
        if match:
            included = service_path(match.group(1))
            if included and chain_has_fprint(included, seen):
                return True
    return False

if chain_has_fprint(source_path):
    print(f"{service} already reaches pam_fprintd through an included PAM stack.")
    raise SystemExit(0)

target = re.compile(r"^\s*(?:auth\s+(?:include|substack)\s+(?:password-auth|system-auth|common-auth|system-login|system-local-login|login)\b|@include\s+common-auth\b)")
lines = source_text.splitlines(keepends=True)
index = next((i for i, line in enumerate(lines) if target.search(line)), None)
if index is None:
    raise SystemExit(f"Could not find a password-auth include in {source_path}; left PAM unchanged")

newline = "auth sufficient pam_fprintd.so\n"
lines.insert(index, newline)
temp = etc / ("." + service + ".goodix55b4.tmp")
temp.write_text("".join(lines))
os.chmod(temp, 0o644)
os.replace(temp, local)
if not created_local:
    backup = etc / (service + ".before-goodix55b4")
    print(f"Original PAM file backed up at {backup}")
print(f"Added auth sufficient pam_fprintd.so to /etc/pam.d/{service}")
PY

PAM_SERVICE=""
DM_TARGET="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
if [[ "$DM_TARGET" == *plasmalogin* ]]; then
    PAM_SERVICE="plasmalogin"
elif [[ "$DM_TARGET" == *sddm* ]]; then
    PAM_SERVICE="sddm"
elif [[ -f /etc/pam.d/plasmalogin || -f /usr/lib/pam.d/plasmalogin ]]; then
    PAM_SERVICE="plasmalogin"
elif [[ -f /etc/pam.d/sddm || -f /usr/lib/pam.d/sddm ]]; then
    PAM_SERVICE="sddm"
fi

if [[ -z "$PAM_SERVICE" ]]; then
    say "Could not identify a Plasma Login Manager/SDDM PAM service. Skipping login PAM setup."
elif confirm "Enable fingerprint authentication at the $PAM_SERVICE login screen? Password remains as fallback."; then
    "$WORKDIR/venv/bin/python" "$WORKDIR/enable-login-pam.py" "$PAM_SERVICE"
    say "At the greeter, select your user, leave the password field empty, and press Enter to start a scan."
    say "If fingerprint login fails, type your account password as usual."
else
    say "Login PAM was left unchanged. Fingerprint enrollment and verification are complete."
fi

say "Setup finished. Enrolled prints can also be managed in KDE System Settings > Users."
if [[ -f "/etc/pam.d/${PAM_SERVICE}.before-goodix55b4" ]]; then
    say "To undo only the PAM change: sudo cp -a /etc/pam.d/${PAM_SERVICE}.before-goodix55b4 /etc/pam.d/${PAM_SERVICE}"
elif [[ -n "$PAM_SERVICE" ]]; then
    say "To undo only the PAM change: sudo rm /etc/pam.d/${PAM_SERVICE} (restores the vendor PAM file)."
fi
