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
    # Selective static link (full -static breaks dynamic Tcl).
    python3 - <<'PY'
import pathlib
p = pathlib.Path("build/platform-mingw-w64.mk")
s = p.read_text()
s = s.replace("LINK_FLAGS:= -static $(LINK_FLAGS)",
              "LINK_FLAGS:= -static-libgcc -static-libstdc++ $(LINK_FLAGS)")
p.write_text(s)
PY
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
    # Force C11 for the pkg-config 0.29.2 bundled glib build. GCC 16+
    # defaults to C23 where `bool` is a keyword, but the upstream
    # pkg-config tarball that openMSX downloads pre-dates C23 and uses
    # `bool` as a variable name. 3rdparty.mk hardcodes CFLAGS at the
    # pkg-config configure call, so env CFLAGS does not propagate —
    # extend the hardcoded flags here.
    python3 - <<'PY'
import pathlib
p = pathlib.Path("build/3rdparty.mk")
s = p.read_text()
# Old glib bundled in pkg-config 0.29.2 (2017) trips a stack of modern GCC defaults:
#   -std=gnu11                          : `bool` is a C23 keyword in GCC 16; glib uses it as var name.
#   -w                                  : suppress -Werror=format= and friends auto-enabled by glib.
#   -Wno-error=incompatible-pointer-types,
#   -Wno-error=implicit-function-declaration,
#   -Wno-error=implicit-int,
#   -Wno-error=return-mismatch          : in GCC 14+ these were promoted from warnings to HARD
#                                         errors by default (-w does not affect them), so each
#                                         needs explicit demotion to keep glib compiling.
s = s.replace(
    'CFLAGS="-Wno-error=int-conversion"',
    'CFLAGS="-Wno-error=int-conversion -Wno-error=incompatible-pointer-types '
    '-Wno-error=implicit-function-declaration -Wno-error=implicit-int '
    '-Wno-error=return-mismatch -std=gnu11 -w"')
p.write_text(s)
PY
fi

echo "openMSX prepared at: ${OPENMSX_DIR}"
