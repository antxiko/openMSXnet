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
cp "${ROOT}/unapinet/UnapiNet.hh" "${ROOT}/unapinet/UnapiNet.cc" \
   "${ROOT}/unapinet/UnapiNetWire.hh" src/unapinet/
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

# Extract generic host-socket helpers (used by UnapiNet) into openMSX's
# Socket.hh/.cc (matches the local build tree). Idempotent.
python3 - <<'PY'
import pathlib
hh = pathlib.Path("src/events/Socket.hh")
s = hh.read_text()
if "sock_makeIPv4" not in s:
    s = s.replace(
        "#include <cassert>\n#include <cstddef>\n#include <string>\n",
        "#include <cassert>\n#include <cstddef>\n#include <cstdint>\n#include <string>\n", 1)
    s = s.replace(
        "#include <sys/socket.h>\n#include <sys/un.h>\n",
        "#include <sys/socket.h>\n#include <sys/select.h>\n#include <sys/un.h>\n", 1)
    s = s.replace(
        "[[nodiscard]] ptrdiff_t sock_send(SOCKET sd, const char* buf, size_t count);\n",
        "[[nodiscard]] ptrdiff_t sock_send(SOCKET sd, const char* buf, size_t count);\n"
        "\n"
        "// Make socket 'sd' non-blocking.\n"
        "void sock_setNonBlocking(SOCKET sd);\n"
        "// Set an integer/boolean socket option (wraps the Windows 'const char*' cast).\n"
        "void sock_setIntOption(SOCKET sd, int level, int optName, int value = 1);\n"
        "// Non-blocking readiness poll (zero timeout): data ready or pending connection.\n"
        "[[nodiscard]] bool sock_readable(SOCKET sd);\n"
        "// Build an IPv4 sockaddr_in (network order); hostIp==0 -> INADDR_ANY.\n"
        "[[nodiscard]] sockaddr_in sock_makeIPv4(uint32_t hostIp, uint16_t port);\n"
        "// Best-effort local IPv4 (host order, 0 if unknown). Sends no packets.\n"
        "[[nodiscard]] uint32_t sock_localIPv4();\n", 1)
    hh.write_text(s)
cc = pathlib.Path("src/events/Socket.cc")
s = cc.read_text()
if "sock_makeIPv4" not in s:
    funcs = (
        "\nvoid sock_setNonBlocking(SOCKET sd)\n{\n"
        "#ifdef _WIN32\n\tu_long mode = 1;\n\tioctlsocket(sd, FIONBIO, &mode);\n"
        "#else\n\tint flags = fcntl(sd, F_GETFL, 0);\n\tfcntl(sd, F_SETFL, flags | O_NONBLOCK);\n#endif\n}\n\n"
        "void sock_setIntOption(SOCKET sd, int level, int optName, int value)\n{\n"
        "\tsetsockopt(sd, level, optName, std::bit_cast<const char*>(&value), sizeof(value));\n}\n\n"
        "bool sock_readable(SOCKET sd)\n{\n"
        "\tfd_set rfds;\n\tFD_ZERO(&rfds);\n\tFD_SET(sd, &rfds);\n\ttimeval tv = {0, 0};\n"
        "\treturn select(static_cast<int>(sd) + 1, &rfds, nullptr, nullptr, &tv) > 0;\n}\n\n"
        "sockaddr_in sock_makeIPv4(uint32_t hostIp, uint16_t port)\n{\n"
        "\tsockaddr_in addr = {};\n\taddr.sin_family = AF_INET;\n"
        "\taddr.sin_addr.s_addr = htonl(hostIp);\n\taddr.sin_port = htons(port);\n\treturn addr;\n}\n\n"
        "uint32_t sock_localIPv4()\n{\n"
        "\tSOCKET sd = socket(AF_INET, SOCK_DGRAM, 0);\n\tif (sd == OPENMSX_INVALID_SOCKET) return 0;\n"
        "\tsockaddr_in remote = sock_makeIPv4(0x08080808, 53);\n\tuint32_t ip = 0;\n"
        "\tif (connect(sd, std::bit_cast<sockaddr*>(&remote), sizeof(remote)) == 0) {\n"
        "\t\tsockaddr_in local = {};\n\t\tsocklen_t len = sizeof(local);\n"
        "\t\tif (getsockname(sd, std::bit_cast<sockaddr*>(&local), &len) == 0) {\n"
        "\t\t\tip = ntohl(local.sin_addr.s_addr);\n\t\t}\n\t}\n\tsock_close(sd);\n\treturn ip;\n}\n")
    s = s.replace("\n} // namespace openmsx\n", funcs + "\n} // namespace openmsx\n", 1)
    cc.write_text(s)
PY

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
