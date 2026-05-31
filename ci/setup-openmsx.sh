#!/usr/bin/env bash
# Clone openMSX at the supported release, drop the UnapiNet extension into
# place, and apply the platform patches required to build cleanly.
#
# Idempotent: safe to re-run. Detects platform via OPENMSX_TARGET_OS
# (autodetected from `uname` if unset).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENMSX_DIR="${OPENMSX_DIR:-${ROOT}/openMSX}"
OPENMSX_REF="${OPENMSX_REF:-RELEASE_21_0}"

if [ -z "${OPENMSX_TARGET_OS:-}" ]; then
    case "$(uname -s)" in
        Linux)              OPENMSX_TARGET_OS=linux   ;;
        Darwin)             OPENMSX_TARGET_OS=darwin  ;;
        MINGW*|MSYS*|CYGWIN*) OPENMSX_TARGET_OS=mingw32 ;;
        *)                  OPENMSX_TARGET_OS=linux   ;;
    esac
fi
echo "Target OS: ${OPENMSX_TARGET_OS}"

if [ ! -d "${OPENMSX_DIR}/.git" ]; then
    git clone --depth 1 --branch "${OPENMSX_REF}" \
        https://github.com/openMSX/openMSX.git "${OPENMSX_DIR}"
fi
cd "${OPENMSX_DIR}"

# Stage the extension sources. openMSX auto-discovers src/*/ subdirs in
# build/main.mk via `find src -type d`, so no makefile registration needed.
mkdir -p src/unapinet share/extensions
cp "${ROOT}/unapinet/UnapiNet.hh" "${ROOT}/unapinet/UnapiNet.cc" src/unapinet/
cp "${ROOT}/unapinet/unapinet.xml" share/extensions/

# Register the device class in DeviceFactory.cc (idempotent).
if ! grep -q '"UnapiNet"' src/DeviceFactory.cc; then
    python3 - <<'PY'
import pathlib
p = pathlib.Path("src/DeviceFactory.cc")
s = p.read_text()
s = s.replace(
    '#include "SunriseIDE.hh"\n',
    '#include "SunriseIDE.hh"\n#include "UnapiNet.hh"\n', 1)
s = s.replace(
    '\t} else if (type == "SunriseIDE") {\n'
    '\t\tresult = std::make_unique<SunriseIDE>(conf);\n',
    '\t} else if (type == "SunriseIDE") {\n'
    '\t\tresult = std::make_unique<SunriseIDE>(conf);\n'
    '\t} else if (type == "UnapiNet") {\n'
    '\t\tresult = std::make_unique<UnapiNet>(conf);\n',
    1)
p.write_text(s)
PY
fi

# All platforms: gate -ldl to Linux only. The stock build adds -ldl on every
# non-mingw target, which fails on macOS where libdl does not exist.
python3 - <<'PY'
import pathlib
p = pathlib.Path("build/main.mk")
s = p.read_text()
old = ("ifneq ($(filter mingw%,$(OPENMSX_TARGET_OS)),)\n"
       "LINK_FLAGS:=-pthread\n"
       "else\n"
       "LINK_FLAGS:=-pthread -ldl\n"
       "endif\n")
new = ("ifneq ($(filter mingw%,$(OPENMSX_TARGET_OS)),)\n"
       "LINK_FLAGS:=-pthread\n"
       "else ifneq ($(filter linux%,$(OPENMSX_TARGET_OS)),)\n"
       "LINK_FLAGS:=-pthread -ldl\n"
       "else\n"
       "LINK_FLAGS:=-pthread\n"
       "endif\n")
if old in s:
    p.write_text(s.replace(old, new))
PY

# Windows MSYS2 patches.
if [ "${OPENMSX_TARGET_OS}" = "mingw32" ] || [ "${OPENMSX_TARGET_OS}" = "mingw-w64" ]; then
    # Python 3 print() and bytes->str decoding in msysutils.
    python3 - <<'PY'
import pathlib
p = pathlib.Path("build/msysutils.py")
s = p.read_text()
s = s.replace("import sys ; print sys.argv[1]",
              "import sys ; print(sys.argv[1])")
s = s.replace(
    "msysRoot = stdoutdata.strip()\n",
    "msysRoot = stdoutdata.strip().decode('utf-8') "
    "if isinstance(stdoutdata, bytes) else stdoutdata.strip()\n", 1)
p.write_text(s)
PY
    # NOTE: previous iterations replaced upstream's `-static` with
    # `-static-libgcc -static-libstdc++` to make the legacy dynamic
    # Tcl link path succeed. We now build via staticbindist (all
    # 3rdparty libs are .a archives) so the upstream `-static` works
    # again — and is required to pull libwinpthread-1.dll's symbols
    # into the .exe instead of leaving it as a runtime DLL dep.
    # Leaving platform-mingw-w64.mk untouched.
    # Winsock 2 + iphlpapi (for IcmpSendEcho).
    python3 - <<'PY'
import pathlib
p = pathlib.Path("build/platform-mingw32.mk")
s = p.read_text()
s = s.replace(
    "-L/mingw/lib -L/mingw/lib/w32api -lwsock32 -lwinmm",
    "-L/mingw/lib -L/mingw/lib/w32api -lws2_32 -lwsock32 -liphlpapi -lwinmm")
p.write_text(s)
PY
fi

echo "openMSX prepared at: ${OPENMSX_DIR}"
