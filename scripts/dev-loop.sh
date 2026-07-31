#!/usr/bin/env bash
# Local dev loop: assemble the TSR, copy it onto the persistent Nextor disk,
# and launch openMSX with the UnapiNet extension. Replaces the copy-paste
# recipe that used to live only in the README (and in heads).
#
# Usage:
#   scripts/dev-loop.sh              # assemble + copy + launch
#   scripts/dev-loop.sh --no-launch  # assemble + copy only
#
# Environment overrides:
#   NEXTOR_DISK   path to the persistent HD image
#                 (default: $USERPROFILE/Documents/openMSX/persistent/Nextor213_IDE/untitled1/nextor_hd.dsk)
#   OPENMSX_BIN   openmsx executable (default: newest under openMSX-master/derived/*/bin/)
#   OPENMSX_SHARE system data dir (default: the share/ next to OPENMSX_BIN's tree)
#
# Requirements: python (for the reassemble check, which also bootstraps the
# pinned Nestor80 into tools/ if missing) and mtools (mcopy/mdir) on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEXTOR_DISK="${NEXTOR_DISK:-$(cygpath -m "${USERPROFILE:-$HOME}")/Documents/openMSX/persistent/Nextor213_IDE/untitled1/nextor_hd.dsk}"

# 1. Assemble (same path as the forja gate: verifies size + pinned N80).
python "${ROOT}/.forja/checks/reassemble.py"

# 2. Refuse to write the disk while an emulator holds it mounted.
if tasklist //FI "IMAGENAME eq openmsx.exe" 2>/dev/null | grep -qi openmsx.exe; then
    echo "[fail] openmsx.exe is running - close it first (writes to a mounted disk get lost)" >&2
    exit 1
fi
if [ ! -f "${NEXTOR_DISK}" ]; then
    echo "[fail] Nextor disk not found: ${NEXTOR_DISK} (set NEXTOR_DISK)" >&2
    exit 1
fi

# 3. Copy onto the FAT partition (@@512 skips the MBR sector; without it
#    mtools sees the MBR and corrupts the image).
mcopy -o -i "${NEXTOR_DISK}@@512" "${ROOT}/msx/unapinet.com" ::UNAPINET.COM
mdir -i "${NEXTOR_DISK}@@512" :: | grep -i unapinet

# 4. Launch.
if [ "${1:-}" = "--no-launch" ]; then
    echo "[ok] TSR updated on ${NEXTOR_DISK}; not launching (--no-launch)"
    exit 0
fi
if [ -z "${OPENMSX_BIN:-}" ]; then
    OPENMSX_BIN="$(ls -t "${ROOT}"/openMSX-master/derived/*/bin/openmsx.exe 2>/dev/null | head -n1 || true)"
fi
if [ -z "${OPENMSX_BIN}" ] || [ ! -f "${OPENMSX_BIN}" ]; then
    echo "[fail] no openmsx binary found (set OPENMSX_BIN, or build openMSX-master)" >&2
    exit 1
fi
if [ -z "${OPENMSX_SHARE:-}" ]; then
    OPENMSX_SHARE="$(cd "$(dirname "${OPENMSX_BIN}")/../../.." && pwd)/share"
fi
echo "[ok] launching ${OPENMSX_BIN}"
OPENMSX_SYSTEM_DATA="${OPENMSX_SHARE}" "${OPENMSX_BIN}" \
    -machine Philips_NMS_8250 -ext Nextor213_IDE -ext unapinet
