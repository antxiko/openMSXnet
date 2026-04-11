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

## Status

### Working

- UNAPI discovery (programs find the `TCP/IP` implementation via EXTBIO)
- DNS resolution (async via host `getaddrinfo`, polling with DNS_Q/DNS_S)
- TCP connections (up to 4 simultaneous, non-blocking connect)
- TCP send/receive with 64KB receive buffer per connection
- Telnet to BBS servers (tested with sotanomsxbbs.org)

### Not working yet

- UDP, ICMP ping, Raw IP
- hget hangs at "Connecting to server..." (TCP_OPEN via UNAPI returns
  handle 0 in some cases, under investigation)

## Files

```
unapinet/
  UnapiNet.hh          C++ extension header
  UnapiNet.cc           C++ extension implementation
  unapinet.xml          openMSX extension descriptor (ports 7Eh-7Fh)

msx/
  unapinet.asm          Z80 TSR, pure ASM (Nestor80 syntax)
  unapinet.c            Legacy C version (archived, replaced by .asm)
  test_unapi.asm         Direct I/O test (ports 7E/7F, no UNAPI)
  test_hget.asm          UNAPI-level test (simulates hget flow)
```

## Build

### Requirements

- [openMSX](https://github.com/openMSX/openMSX) source (tested with
  RELEASE_21_0)
- [MSYS2](https://www.msys2.org/) MINGW64 environment (for Windows)
- [Nestor80](https://github.com/Konamiman/Nestor80) Z80 assembler
- [Nextor 2.1.3](https://github.com/Konamiman/Nextor) SunriseIDE ROM

### MSYS2 packages

```bash
pacman -S --needed mingw-w64-x86_64-{gcc,SDL2,SDL2_ttf,freetype,glew,libpng,tcl,zlib,libogg,libvorbis,libtheora,mtools}
```

### Building the openMSX extension

1. Clone openMSX and checkout RELEASE_21_0:
   ```bash
   git clone https://github.com/openMSX/openMSX.git
   cd openMSX && git checkout RELEASE_21_0
   ```

2. Copy our source files:
   ```bash
   mkdir -p src/unapinet
   cp /path/to/openMSXnet/unapinet/UnapiNet.{hh,cc} src/unapinet/
   cp /path/to/openMSXnet/unapinet/unapinet.xml share/extensions/
   ```

3. Register the device in `src/DeviceFactory.cc`:
   ```cpp
   #include "UnapiNet.hh"
   // In the create() function, add:
   } else if (type == "UnapiNet") {
       result = std::make_unique<UnapiNet>(conf);
   }
   ```

4. Apply Windows build patches (RELEASE_21_0 has issues with MSYS2):

   **`build/msysutils.py`** -- Python 3 compatibility:
   ```python
   # Line 14: fix print syntax
   '"%s" -c \'import sys ; print(sys.argv[1])\' /'
   # Line 27: fix bytes/str
   msysRoot = stdoutdata.strip().decode('utf-8') if isinstance(stdoutdata, bytes) else stdoutdata.strip()
   ```

   **`build/platform-mingw-w64.mk`** -- allow dynamic linking:
   ```makefile
   # Line 25: change -static to:
   LINK_FLAGS:= -static-libgcc -static-libstdc++ $(LINK_FLAGS)
   ```

   **`build/platform-mingw32.mk`** -- add Winsock 2:
   ```makefile
   # Line 19: add -lws2_32
   -L/mingw/lib -L/mingw/lib/w32api -lws2_32 -lwsock32 -lwinmm ...
   ```

   **`build/main.mk`** -- remove -ldl on non-Linux:
   ```makefile
   # Lines 94-98: change to only add -ldl on Linux
   LINK_FLAGS:=-pthread
   ifneq ($(filter linux%,$(OPENMSX_TARGET_OS)),)
   LINK_FLAGS+=-ldl
   endif
   ```

5. Compile from MSYS2 MINGW64 shell:
   ```bash
   export PYTHON=/mingw64/bin/python3 MSYSCON=yes SHELL=/usr/bin/bash TCL_CONFIG=/mingw64/lib
   make -j8
   ```

6. Copy runtime DLLs to the binary directory
   (`derived/x86_64-mingw-w64-opt/bin/`):
   ```
   SDL2.dll SDL2_ttf.dll libfreetype-6.dll glew32.dll libogg-0.dll
   libpng16-16.dll libtheoradec-2.dll libvorbis-0.dll tcl86.dll
   zlib1.dll libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll
   libbz2-1.dll libbrotlidec.dll libbrotlicommon.dll libharfbuzz-0.dll
   libglib-2.0-0.dll libintl-8.dll libiconv-2.dll libpcre2-8-0.dll
   libgraphite2.dll
   ```
   All found in `/mingw64/bin/`.

### Building the MSX TSR

```bash
N80 msx/unapinet.asm msx/unapinet.com --direct-output-write
```

Output: `unapinet.com` (~1.5KB).

### Running

```bash
openmsx -machine Philips_NMS_8250 \
        -ext Nextor213_IDE \
        -ext unapinet
```

The Nextor HD image must contain `NEXTOR.SYS` and `COMMAND2.COM`.
Copy `unapinet.com` to the HD image (e.g. with `mcopy` from mtools).
Run `UNAPINET.COM` at the Nextor prompt to install the TSR.

## I/O protocol

The extension uses two I/O ports for all communication between the
Z80 TSR and the C++ host code.

### Port map

| Port | Write | Read |
|------|-------|------|
| 7Eh  | Command byte (triggers execution) | Status (00=OK, 01=ERR, 02=DATA) |
| 7Fh  | Parameter byte (accumulated in buffer) | Result byte (auto-advancing) |

### Flow

1. Write 0 or more parameter bytes to port 7Fh (buffered)
2. Write command byte to port 7Eh (triggers processing)
3. Read status from port 7Eh until 02h (DATA ready)
4. Read result bytes from port 7Fh one at a time

Writing to port 7Fh while a previous result is still pending
automatically discards the old result. This prevents deadlocks
when the MSX side doesn't consume all result bytes.

### Command table

| Cmd  | Name        | Parameters (via 7Fh)       | Result (via 7Fh)                    |
|------|-------------|----------------------------|-------------------------------------|
| 00h  | PING        | --                         | 1 byte: ABh (magic)                |
| 01h  | DNS_QUERY   | hostname + 00h             | 1b status [+ 4b IP if immediate]   |
| 02h  | DNS_STATUS  | --                         | 1b status [+ 4b IP if complete]    |
| 03h  | TCP_OPEN    | IP[4] + port[2 LE]         | 1b handle (0 = error)              |
| 04h  | TCP_SEND    | handle + len[2 LE] + data  | 1b status (0 = OK)                 |
| 05h  | TCP_RECV    | handle + maxlen[2 LE]      | len[2 LE] + data                   |
| 06h  | TCP_CLOSE   | handle                     | 1b status                          |
| 07h  | TCP_STATE   | handle                     | state + avail[2 LE] + close_reason |
| 08h  | TCP_ABORT   | handle                     | 1b status                          |
| 0Dh  | GET_LOCALIP | --                         | 4 bytes IP (big-endian)            |
| 0Eh  | NET_STATE   | --                         | 1b state (2 = open)                |
| 10h  | QUERY_CAP   | --                         | 2 bytes: cap0, cap1                |

### UNAPI functions implemented

| Fn | Name            | Bridge cmd | Notes                          |
|----|-----------------|------------|--------------------------------|
| 0  | UNAPI_GET_INFO  | (local)    | Returns impl name, version     |
| 1  | TCPIP_GET_CAPAB | (local)    | Hardcoded caps (DNS + TCP)     |
| 2  | TCPIP_GET_IPINFO| 0Dh        | Local IP from host, rest fixed |
| 3  | TCPIP_NET_STATE | 0Eh        | Always "open"                  |
| 6  | TCPIP_DNS_Q     | 01h        | Async DNS start                |
| 7  | TCPIP_DNS_S     | 02h        | DNS poll/result                |
| 13 | TCPIP_TCP_OPEN  | 03h        | Non-blocking connect           |
| 14 | TCPIP_TCP_CLOSE | 06h        | Graceful close (FIN)           |
| 15 | TCPIP_TCP_ABORT | 08h        | Immediate close (RST)          |
| 16 | TCPIP_TCP_STATE | 07h        | Connection state + avail bytes |
| 17 | TCPIP_TCP_SEND  | 04h        | Send data                      |
| 18 | TCPIP_TCP_RCV   | 05h        | Receive data                   |
| *  | (others)        | --         | Returns ERR_NOT_IMP            |

### TCP states (from UNAPI spec)

| Value | State       |
|-------|-------------|
| 0     | CLOSED      |
| 2     | SYN_SENT    |
| 4     | ESTABLISHED |
| 7     | CLOSE_WAIT  |

## C++ extension internals

- **SocketActivator**: RAII wrapper for WSAStartup on Windows
- **Background thread** (`receiverLoop`): polls all active TCP sockets
  with `select()` every 10ms, buffers incoming data in per-connection
  `std::deque<uint8_t>`, detects connect completion (SYN_SENT ->
  ESTABLISHED) and remote close (CLOSE_WAIT)
- **DNS thread**: `getaddrinfo()` runs in a detached thread; MSX polls
  via DNS_STATUS
- **Non-blocking connect**: `connect()` returns WSAEWOULDBLOCK/EINPROGRESS;
  `receiverLoop` detects completion via writable fd_set
- **intptr_t for SOCKET**: avoids including `winsock2.h` in the header
  (which defines a `interface` macro that breaks other openMSX headers)
- **Save states**: network state is not serialized; connections are lost
  on save/load

## Known issues

- **hget hangs at "Connecting to server..."**: TCP_OPEN returns handle 0
  when called through the UNAPI mapper segment in some cases. Direct I/O
  test works fine. Under investigation.
- **DLL dependencies**: the Windows build links dynamically (required for
  Tcl). All DLLs from `/mingw64/bin/` must be copied to the binary dir.
- **openMSX RELEASE_21_0 build**: requires 4 patches for MSYS2
  compatibility (see Build section above).

## References

- [MSX UNAPI specification](https://github.com/Konamiman/MSX-UNAPI-specification)
- [openMSX](https://openmsx.org/)
- [Nextor](https://github.com/Konamiman/Nextor)
- [Nestor80](https://github.com/Konamiman/Nestor80)
- [Telnet client source](https://github.com/ducasp/MSX-Development/tree/master/UNAPI/TELNET) (by Oduvaldo Pavan Junior)

## License

MIT
