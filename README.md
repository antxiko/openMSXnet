# openMSXnet

Real TCP/IP networking for MSX software running in openMSX.

A C++ extension for the openMSX emulator that bridges the MSX UNAPI TCP/IP
specification to the host operating system's BSD socket API. MSX programs
that use UNAPI (hget, telnet, IRC clients, etc.) get transparent internet
access through the host's network stack.

## How it works

```
MSX program (hget, telnet, ...)
        |
    UNAPI TCP/IP calls
        |
UNAPINET.COM (Z80 TSR in mapper segment)
        |  I/O ports 7Eh / 7Fh
UnapiNet extension (C++ inside openMSX)
        |  BSD sockets + threads
    Host network
```

The TSR installs in a memory mapper segment via the UNAPI RAM helper
(included in Nextor 2.1+). It hooks EXTBIO and registers as a `TCP/IP`
UNAPI implementation. Function calls are dispatched through two I/O ports
to the C++ extension, which handles DNS resolution, TCP connections, and
data transfer using real sockets.

## What works

- UNAPI discovery (programs find the implementation)
- DNS resolution (async, via host `getaddrinfo`)
- TCP connections (up to 4 simultaneous, non-blocking connect)
- TCP send/receive with 64KB receive buffer per connection
- Telnet to BBS servers (tested and working)
- hget HTTP downloads (under debugging)

## What doesn't work yet

- UDP
- ICMP ping
- Raw IP connections
- hget has issues with TCP state polling through the UNAPI call chain (investigating)

## Files

```
unapinet/
  UnapiNet.hh        C++ extension header
  UnapiNet.cc         C++ extension implementation
  unapinet.xml        openMSX extension descriptor

msx/
  unapinet.asm        Z80 TSR (assembled with Nestor80)
  test_unapi.asm      I/O-level test (ports 7E/7F direct)
  test_hget.asm       UNAPI-level test (simulates hget flow)
```

## Build

### Requirements

- [openMSX](https://github.com/openMSX/openMSX) source (tested with RELEASE_21_0)
- MSYS2 MINGW64 with: gcc, SDL2, SDL2_ttf, Tcl, libpng, freetype, glew, zlib, ogg, vorbis, theora
- [Nestor80](https://github.com/Konamiman/Nestor80) Z80 assembler (for the TSR)
- [Nextor 2.1.3](https://github.com/Konamiman/Nextor) SunriseIDE ROM

### openMSX extension

Copy `unapinet/UnapiNet.hh` and `unapinet/UnapiNet.cc` to `src/unapinet/` in the
openMSX source tree. Copy `unapinet/unapinet.xml` to `share/extensions/`.

Register the device in `src/DeviceFactory.cc`:

```cpp
#include "UnapiNet.hh"
// ...
} else if (type == "UnapiNet") {
    result = std::make_unique<UnapiNet>(conf);
}
```

The Makefile-based build system auto-discovers sources via `find src -type d`,
so no build file changes are needed.

Compile openMSX from MSYS2 MINGW64:

```bash
export PYTHON=/mingw64/bin/python3 MSYSCON=yes SHELL=/usr/bin/bash TCL_CONFIG=/mingw64/lib
make -j8
```

Note: RELEASE_21_0 has build issues on Windows that require patching
`build/msysutils.py` (Python 3 syntax), `build/platform-mingw-w64.mk`
(static linking), and `build/platform-mingw32.mk` (Winsock 2).
See the project memory for details.

### MSX TSR

```bash
N80 msx/unapinet.asm msx/unapinet.com --direct-output-write
```

### Running

```bash
openmsx -machine Philips_NMS_8250 \
        -ext Nextor213_IDE \
        -ext unapinet
```

In Nextor, run `UNAPINET.COM` to install the TSR. Then use any UNAPI TCP/IP
program normally.

## Protocol

The extension uses two I/O ports:

| Port | Write | Read |
|------|-------|------|
| 7Eh  | Command byte | Status (00=OK, 01=ERR, 02=DATA) |
| 7Fh  | Parameter byte (accumulated) | Result byte (sequential) |

Parameters are written to 7Fh before the command. The command byte triggers
execution. Results are read back from 7Fh one byte at a time.

Writing to 7Fh while a previous result is pending discards it (prevents
state machine deadlocks).

## References

- [MSX UNAPI specification](https://github.com/Konamiman/MSX-UNAPI-specification)
- [openMSX](https://openmsx.org/)
- [Nextor](https://github.com/Konamiman/Nextor)
- [Nestor80](https://github.com/Konamiman/Nestor80)

## License

MIT
