# openMSXnet

An MSX TCP/IP UNAPI implementation that exposes the host operating system's
network stack to MSX software running under the [openMSX](https://openmsx.org/)
emulator.

The implementation consists of two cooperating components:

- A C++ device extension compiled into openMSX, which holds real BSD sockets
  and a background polling thread on the host side.
- A Z80 TSR (`UNAPINET.COM`) that installs in a memory mapper segment under
  Nextor / MSX-DOS 2, hooks `EXTBIO`, and exposes a standards-compliant
  TCP/IP UNAPI 1.1 interface to client programs. Function calls are
  marshalled through a pair of I/O ports to the C++ device.

Programs that target the UNAPI TCP/IP specification (such as `hget`, `telnet`,
`sntp`) run unmodified.

## Architecture

```
MSX program (hget, telnet, sntp, ...)
        │
        │  UNAPI TCP/IP function calls
        ▼
UNAPINET.COM    (Z80 TSR in mapper segment)
        │
        │  I/O ports 7Eh / 7Fh
        ▼
UnapiNet device (C++, inside openMSX)
        │
        │  BSD sockets, threads
        ▼
   Host OS network stack
```

## Implementation status

### Implemented and tested

| Feature | Notes |
|---------|-------|
| UNAPI discovery via `EXTBIO` (DE=2222h, ARG=`"TCP/IP"`) | Programs locate the implementation through Nextor's RAM helper |
| DNS resolution | Asynchronous, backed by host `getaddrinfo()` |
| TCP active connections | Up to 4 simultaneous, non-blocking `connect()` |
| TCP send / receive | 64 KiB receive buffer per connection |
| TCP passive mode (listen) | `bind()` + `listen()` with non-blocking `accept()` in the receiver loop |
| UDP datagrams | Up to 4 simultaneous, automatic fallback when bind to a privileged port (<1024) is denied |
| ICMP echo (ping) | Uses Windows `IcmpSendEcho` API; no admin required |
| `TCPIP_WAIT` (fn 29) | `EI`/`HALT` idiom to release a 50/60 Hz tick |
| `TCPIP_GET_IPINFO` | Local IP discovered via UDP socket trick to 8.8.8.8 |

Verified against:
- **`telnet`** (BBS sessions, including ANSI screens with sotanomsxbbs.org)
- **`hget`** (HTTP/1.1 chunked transfer, tested with example.com)
- **`sntp`** (clock synchronisation with `pool.ntp.org`)
- **`tftp`** (file download from a local TFTP server)
- **`ping`** (ICMP echo request/reply against 8.8.8.8)
- **MSXon clients** (multiplayer game clients built with MSXgl's `unapi_tcp` library — `tetris.com`, `lobby.com`, etc.)

### Not implemented

| UNAPI function | Reason |
|----------------|--------|
| `TCPIP_TCP_DISCARD` (fn 19) | No client encountered relies on it. |
| Raw IP (fn 20-24) | Not advertised. |
| `TCPIP_CONFIG_*` (fn 25-28) | Network configuration is delegated to the host OS. |

### Known limitations

- Save states do not preserve socket state; open connections are lost on
  load.
- TLS is not supported. Plain HTTP/HTTPS clients work for `http://` only.

## Repository layout

```
unapinet/
  UnapiNet.hh           C++ device class declaration
  UnapiNet.cc           C++ device implementation
  unapinet.xml          openMSX device descriptor (claims I/O ports 7Eh-7Fh)

msx/
  unapinet.asm          Z80 TSR (Nestor80 syntax)
  test_unapi.asm        Direct I/O regression test (does not exercise the dispatcher)
  test_hget.asm         End-to-end test mirroring hget's call sequence
```

## Building

### Prerequisites

- [openMSX](https://github.com/openMSX/openMSX) source tree, tested with
  `RELEASE_21_0`
- [Nestor80](https://github.com/Konamiman/Nestor80) Z80 assembler
- A Nextor 2.1.x ROM (the MSX RAM helper used by the TSR is part of Nextor)
- On Windows: [MSYS2](https://www.msys2.org/) MINGW64 environment with the
  packages listed below

```bash
pacman -S --needed mingw-w64-x86_64-{gcc,SDL2,SDL2_ttf,freetype,glew,libpng,tcl,zlib,libogg,libvorbis,libtheora,mtools}
```

### openMSX device extension

1. Clone openMSX and check out the supported release:
   ```bash
   git clone https://github.com/openMSX/openMSX.git
   cd openMSX && git checkout RELEASE_21_0
   ```

2. Stage the device sources:
   ```bash
   mkdir -p src/unapinet
   cp /path/to/openMSXnet/unapinet/UnapiNet.{hh,cc} src/unapinet/
   cp /path/to/openMSXnet/unapinet/unapinet.xml share/extensions/
   ```

3. Register the device in `src/DeviceFactory.cc`:
   ```cpp
   #include "UnapiNet.hh"
   // ...
   } else if (type == "UnapiNet") {
       result = std::make_unique<UnapiNet>(conf);
   }
   ```

4. Apply the following patches to make `RELEASE_21_0` build cleanly under
   MSYS2 MINGW64:

   `build/msysutils.py` — Python 3 compatibility:
   ```python
   '"%s" -c \'import sys ; print(sys.argv[1])\' /'
   msysRoot = stdoutdata.strip().decode('utf-8') if isinstance(stdoutdata, bytes) else stdoutdata.strip()
   ```

   `build/platform-mingw-w64.mk` — replace the global `-static` with a
   selective static link of the GCC runtime, otherwise Tcl cannot be
   linked dynamically:
   ```makefile
   LINK_FLAGS:= -static-libgcc -static-libstdc++ $(LINK_FLAGS)
   ```

   `build/platform-mingw32.mk` — add Winsock 2 (the default `-lwsock32` is
   Winsock 1 and lacks `getaddrinfo`, `inet_pton`, `freeaddrinfo`):
   ```makefile
   -L/mingw/lib -L/mingw/lib/w32api -lws2_32 -lwsock32 -lwinmm ...
   ```

   `build/main.mk` — `-ldl` is Linux-specific:
   ```makefile
   LINK_FLAGS:=-pthread
   ifneq ($(filter linux%,$(OPENMSX_TARGET_OS)),)
   LINK_FLAGS+=-ldl
   endif
   ```

5. Build from the MSYS2 MINGW64 shell:
   ```bash
   export PYTHON=/mingw64/bin/python3 MSYSCON=yes SHELL=/usr/bin/bash TCL_CONFIG=/mingw64/lib
   make -j8
   ```

6. Copy the runtime DLLs alongside the resulting `openmsx.exe` (in
   `derived/x86_64-mingw-w64-opt/bin/`):
   ```
   SDL2.dll SDL2_ttf.dll libfreetype-6.dll glew32.dll libogg-0.dll
   libpng16-16.dll libtheoradec-2.dll libvorbis-0.dll tcl86.dll
   zlib1.dll libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll
   libbz2-1.dll libbrotlidec.dll libbrotlicommon.dll libharfbuzz-0.dll
   libglib-2.0-0.dll libintl-8.dll libiconv-2.dll libpcre2-8-0.dll
   libgraphite2.dll
   ```

### MSX TSR

```bash
N80 msx/unapinet.asm msx/unapinet.com --direct-output-write
```

The output binary is roughly 2 KiB. Copy it to a Nextor disk image
alongside `NEXTOR.SYS` and `COMMAND2.COM` (for example with `mcopy`
from the `mtools` package).

### Running

```bash
openmsx -machine Philips_NMS_8250 \
        -ext Nextor213_IDE \
        -ext unapinet
```

At the Nextor prompt, run `UNAPINET.COM` once to install the TSR. From
that point on, any UNAPI TCP/IP client will discover the implementation
through `EXTBIO` and route its calls through the bridge.

## Bridge protocol

All communication between the Z80 TSR and the C++ device flows through two
I/O ports.

| Port | Write | Read |
|------|-------|------|
| 7Eh  | Command byte; triggers execution | Status (00=OK, 01=ERR, 02=DATA available) |
| 7Fh  | Parameter byte; appended to a per-command buffer | Result byte; auto-advances on each read |

The MSX appends parameter bytes to port 7Fh, then writes a command byte
to port 7Eh. The device processes the command synchronously (DNS is
serviced asynchronously through a worker thread but its dispatch is
non-blocking), populates the result buffer, and signals `DATA available`
on port 7Eh. The MSX then reads the result bytes sequentially from port
7Fh.

Writing to port 7Fh while a previous result is still pending discards
the stale result. This avoids deadlocks if the MSX side fails to drain
all bytes from a previous call.

### Bridge command set

| Cmd  | Mnemonic       | Parameters (port 7Fh)                | Result (port 7Fh)                   |
|------|----------------|--------------------------------------|-------------------------------------|
| 00h  | `PING`         | -                                    | 1 byte: ABh                         |
| 01h  | `DNS_QUERY`    | hostname + 00h                       | 1 byte status [+ 4 bytes IP]        |
| 02h  | `DNS_STATUS`   | -                                    | 1 byte status [+ 4 bytes IP]        |
| 03h  | `TCP_OPEN`     | IP[4] + port[2 LE]                   | 1 byte handle (0 = error)           |
| 04h  | `TCP_SEND`     | handle + len[2 LE] + data            | 1 byte status                       |
| 05h  | `TCP_RECV`     | handle + maxlen[2 LE]                | len[2 LE] + data                    |
| 06h  | `TCP_CLOSE`    | handle                               | 1 byte status                       |
| 07h  | `TCP_STATE`    | handle                               | state + avail[2 LE] + close_reason  |
| 08h  | `TCP_ABORT`    | handle                               | 1 byte status                       |
| 09h  | `UDP_OPEN`     | local_port[2 LE]                     | 1 byte handle (0 = error)           |
| 0Ah  | `UDP_CLOSE`    | handle                               | 1 byte status                       |
| 0Bh  | `UDP_STATE`    | handle                               | size[2 LE] of next datagram         |
| 0Ch  | `UDP_SEND`     | handle + dest_IP[4] + port[2 LE] + len[2 LE] + data | 1 byte status        |
| 0Dh  | `GET_LOCALIP`  | -                                    | 4 bytes IP (network order)          |
| 0Eh  | `NET_STATE`    | -                                    | 1 byte (2 = open)                   |
| 0Fh  | `UDP_RECV`     | handle + maxlen[2 LE]                | src_IP[4] + src_port[2 LE] + len[2 LE] + data |
| 10h  | `QUERY_CAP`    | -                                    | 2 bytes: cap0, cap1                 |
| 11h  | `ICMP_SEND`    | IP[4] + TTL[1] + ID[2 LE] + SEQ[2 LE] + len[2 LE] | 1 byte status             |
| 12h  | `ICMP_RECV`    | -                                    | has_data[1] + [IP[4]+TTL[1]+ID[2]+SEQ[2]+len[2]] |

### UNAPI dispatch table

| Fn | UNAPI name        | Backed by             |
|----|-------------------|-----------------------|
| 0  | `UNAPI_GET_INFO`  | local                 |
| 1  | `TCPIP_GET_CAPAB` | local (hardcoded)     |
| 2  | `TCPIP_GET_IPINFO`| `GET_LOCALIP` (idx 1) |
| 3  | `TCPIP_NET_STATE` | `NET_STATE`           |
| 4  | `TCPIP_SEND_ECHO` | `ICMP_SEND`           |
| 5  | `TCPIP_RCV_ECHO`  | `ICMP_RECV`           |
| 6  | `TCPIP_DNS_Q`     | `DNS_QUERY`           |
| 7  | `TCPIP_DNS_S`     | `DNS_STATUS`          |
| 8  | `TCPIP_UDP_OPEN`  | `UDP_OPEN`            |
| 9  | `TCPIP_UDP_CLOSE` | `UDP_CLOSE`           |
| 10 | `TCPIP_UDP_STATE` | `UDP_STATE`           |
| 11 | `TCPIP_UDP_SEND`  | `UDP_SEND`            |
| 12 | `TCPIP_UDP_RCV`   | `UDP_RECV`            |
| 13 | `TCPIP_TCP_OPEN`  | `TCP_OPEN` (active or passive depending on flags) |
| 14 | `TCPIP_TCP_CLOSE` | `TCP_CLOSE`           |
| 15 | `TCPIP_TCP_ABORT` | `TCP_ABORT`           |
| 16 | `TCPIP_TCP_STATE` | `TCP_STATE`           |
| 17 | `TCPIP_TCP_SEND`  | `TCP_SEND`            |
| 18 | `TCPIP_TCP_RCV`   | `TCP_RECV`            |
| 29 | `TCPIP_WAIT`      | local (`ei`/`halt`)   |
| *  | (others)          | `ERR_NOT_IMP`         |

## Implementation notes

### Device side (C++)

- A `SocketActivator` RAII wrapper drives `WSAStartup` / `WSACleanup` on
  Windows.
- A background thread (`receiverLoop`) runs continuously while the device
  is alive. It iterates over all open TCP and UDP sockets, polls them with
  `select()` on a 10 ms cadence, drains any pending data into per-socket
  queues, and detects connection state transitions (`SYN_SENT` →
  `ESTABLISHED`, remote half-close → `CLOSE_WAIT`).
- DNS resolution is offloaded to a detached worker thread so that the
  emulator does not block during `getaddrinfo()`.
- `connect()` is always issued non-blocking; the receiver loop completes
  the connection state machine.
- The header deliberately uses `intptr_t` for socket descriptors so that
  `winsock2.h` can stay out of the public header. `winsock2.h` transitively
  pulls in `windows.h`, which defines `interface` as a preprocessor macro
  that breaks unrelated openMSX headers.

### TSR side (Z80)

- The TSR follows Konamiman's reference RAM-resident pattern:
  installer at 0100h allocates a system mapper segment via DOS 2 mapper
  routines, copies the resident block to 4000h of that segment, and
  patches `EXTBIO` to use the RAM helper's segment-call routine.
- The dispatcher at `UNAPI_ENTRY` runs each implemented function with
  `ei` immediately preceding the final `ret`. This is required because
  Nextor's RAM helper does not unconditionally re-enable interrupts on
  return, and several UNAPI clients rely on `*SYSTIMER` (0FC9Eh) ticking
  while they spin.
- `TCPIP_WAIT` (function 29) is intercepted ahead of the dispatch table
  via a fast path. The implementation is `ei` / `halt` / `ret`, which
  blocks until the next 50/60 Hz interrupt and matches the spec
  ("block until the next timer interrupt has completed its processing
  step").

### `TCPIP_TCP_STATE` must not write to (HL)

Per the UNAPI TCP/IP 1.1 spec, function 16 returns connection state via
registers (`B`=state, `C`=close_reason, `HL`=available bytes,
`DE`=urgent bytes, `IX`=output buffer free space). Some clients pass a
non-zero `HL` to indicate they want a full info block written there, but
the dominant client library in the wild (MSXgl's `unapi_tcp.asm`) uses
`HL` purely as the address of its **own** internal struct that it
populates from the returned registers — it does not expect the
implementation to write into it. Writing 8 bytes of remote/local
endpoint info to that pointer corrupts the caller's struct and crashes
the application a few frames later when the corrupted fields get
interpreted as buffer pointers.

Resolution: `FN_TCP_STATE` reads the 12-byte response from the bridge,
returns the first four bytes through registers, and discards the
remote-IP / port / local-port tail. Servers that genuinely need the
peer endpoint can recover it from the source address of received data
in the application protocol.

### TCP_CLOSE serialisation

`cmdTcpClose` issues `shutdown(SD_SEND)` and transitions the connection
to `CLOSE_WAIT`. It does **not** call `closesocket()` or take the
per-connection mutex while transitioning. Both responsibilities are
delegated to the receiver loop, which observes `recv() == 0` (peer FIN)
and tears the socket down. Holding the mutex across both `shutdown()`
and `closesocket()` deadlocks the emulator if the receiver thread is
concurrently calling into the same socket.

## References

- [MSX UNAPI specification (Konamiman)](https://github.com/Konamiman/MSX-UNAPI-specification)
- [openMSX](https://openmsx.org/)
- [Nextor](https://github.com/Konamiman/Nextor)
- [Nestor80 assembler](https://github.com/Konamiman/Nestor80)
- [TFTP / hget / telnet for MSX UNAPI (ducasp)](https://github.com/ducasp/MSX-Development/tree/master/UNAPI)

## License

MIT
