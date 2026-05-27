# openMSXnet — User Guide

This guide explains how to install and run an `openmsx` build that includes
the **UnapiNet** extension on Windows, Linux and macOS, and how to make MSX
software see real TCP/IP networking through the host's network stack.

If you only want to *use* openMSXnet, this is the document you need. For
building from source, see [README.md](../README.md).

---

## 1. What you need

### Files produced by the build

Every tagged release on GitHub attaches one ZIP per platform plus the
MSX TSR:

| Asset                          | Contents                                                                                  |
|--------------------------------|-------------------------------------------------------------------------------------------|
| `openmsx-windows-x86_64.zip`   | `openmsx.exe` + the full set of MinGW runtime DLLs it needs + `share/`. Extract and run.  |
| `openmsx-linux-x86_64.zip`     | `openmsx` ELF binary + `share/`. Install matching SDL2/Tcl/etc. via your package manager. |
| `openmsx-macos-arm64.zip`      | `openmsx` Mach-O binary + `share/`. Install dependencies via Homebrew.                    |
| `UNAPINET.COM`                 | The Z80 TSR (~2 KiB) that you copy onto the MSX disk image.                               |

Download from the **Releases** page:
<https://github.com/antxiko/openMSXnet/releases> → pick the latest tag
(e.g. `v0.9.4`) → download the assets you need.

> The Windows ZIP bundles every runtime DLL that `openmsx.exe` (and its
> transitive deps) needs. The CI workflow walks the import table to a
> fixed point, so the set is complete and self-contained at the
> directory level — extract the ZIP and run, no separate MinGW install
> required.

### Other things you need to gather yourself

openMSX itself contains no MSX system ROMs or BIOSes. You will also need:

1. A **Nextor 2.1.x ROM** (it provides the RAM-helper that the TSR depends
   on). The most reliable source is the official Nextor distribution at
   <https://github.com/Konamiman/Nextor/releases>. After unpacking, the
   relevant file is typically `Nextor-2.1.X.SunriseIDE.ROM` (or
   `*.MegaFlashSCC*.ROM`, depending on the cartridge model you want to
   emulate).
2. A **machine ROM set** (e.g. a Philips NMS 8250 BIOS / Sub-ROM /
   Disk-ROM). openMSX ships only the device descriptors; the binary ROM
   files are not redistributable. The machine descriptor's XML lists the
   exact `<sha1>` hashes openMSX expects.
3. A **hard-disk image** with Nextor installed on it, plus
   `COMMAND2.COM` and `NEXTOR.SYS`. You can format a blank `.dsk` from
   inside openMSX itself (`FDISK` and `FORMAT`) the first time you boot.

---

## 2. Where openMSX looks for files

openMSX uses two well-known directories at runtime:

- **System data** — read-only, ships with the build. Contains `share/`,
  including `share/extensions/` (where each extension's `.xml` lives).
  Set the env var `OPENMSX_SYSTEM_DATA` to override.
- **User data** — per-user, writeable. Contains your machine ROMs,
  configuration, save states. Defaults are below.

| OS      | User data directory                       |
|---------|-------------------------------------------|
| Windows | `%USERPROFILE%\Documents\openMSX`         |
| Linux   | `~/.openMSX`                              |
| macOS   | `~/Library/openMSX` *or* `~/.openMSX`     |

Drop your machine ROMs into `<user-data>/share/systemroms/`. Drop
HD images into `<user-data>/persistent/` (or anywhere — you reference
them by path on the command line).

---

## 3. Installing on Windows

### 3.1 Unpack the build

1. Download `openmsx-windows-x86_64.zip` from the latest release at
   <https://github.com/antxiko/openMSXnet/releases>.
2. Extract somewhere stable, for example `C:\Tools\openmsx\`. The folder
   contains `openmsx.exe`, the runtime DLLs it depends on (all bundled
   in the ZIP — extract everything together) and a `share/` subdirectory.
3. Verify `share/extensions/unapinet.xml` is present.

### 3.2 Provide ROMs

1. Create the directory `%USERPROFILE%\Documents\openMSX\share\systemroms\`.
2. Copy your machine BIOS files there.
3. Copy the Nextor ROM into the same `systemroms` folder.

### 3.3 Run

Open a PowerShell or `cmd` window in `C:\Tools\openmsx\` and run:

```powershell
.\openmsx.exe -machine Philips_NMS_8250 -ext Nextor213_IDE -ext unapinet `
              -hda C:\path\to\nextor_hd.dsk
```

The first time, openMSX will complain about missing ROMs and tell you the
SHA-1 it expects — copy the matching files into `systemroms` and try
again.

### 3.4 Install the TSR onto the disk image

Outside the emulator, with openMSX **closed** (otherwise the disk image
is locked):

```powershell
# mtools comes with MSYS2; you can install it with `pacman -S mtools`
mcopy -o -i "C:\path\to\nextor_hd.dsk@@512" UNAPINET.COM ::
mdir   -i "C:\path\to\nextor_hd.dsk@@512" ::UNAPINET.COM
```

The `@@512` offset assumes Nextor was installed leaving a 512-byte master
boot sector. If `mcopy` rejects the image, try `@@0`.

Alternatively, drop `UNAPINET.COM` into a folder, mount it as the
floppy drive (`-diska`) and copy with `COPY` from inside the emulated
MSX.

### 3.5 Firewall

Windows Firewall will prompt the first time openMSX opens a TCP socket.
Allow access for **Private networks** at minimum; **Public networks** is
optional. UDP ports under 1024 (e.g. SNTP's 123) require admin
privileges; openMSXnet automatically falls back to an ephemeral port
when this happens.

---

## 4. Installing on Linux

### 4.1 Unpack the build

```bash
mkdir -p ~/Apps/openmsx && cd ~/Apps/openmsx
unzip ~/Downloads/openmsx-linux-x86_64.zip
chmod +x openmsx
```

### 4.2 Install runtime libraries

The CI binary is dynamically linked against the standard set of openMSX
dependencies. On Debian / Ubuntu:

```bash
sudo apt-get install -y \
    libsdl2-2.0-0 libsdl2-ttf-2.0-0 libfreetype6 libglew2.2 \
    libpng16-16 libxml2 libtcl8.6 libogg0 libvorbis0a libvorbisfile3 \
    libtheora0
```

On Fedora / RHEL:

```bash
sudo dnf install -y SDL2 SDL2_ttf freetype glew libpng libxml2 \
    tcl libogg libvorbis libtheora
```

On Arch / Manjaro:

```bash
sudo pacman -S sdl2 sdl2_ttf freetype2 glew libpng libxml2 tcl \
    libogg libvorbis libtheora
```

### 4.3 Provide ROMs

```bash
mkdir -p ~/.openMSX/share/systemroms
cp Philips_NMS_8250_BIOS.rom Philips_NMS_8250_SubROM.rom \
   Nextor-2.1.X.SunriseIDE.ROM ~/.openMSX/share/systemroms/
```

### 4.4 Run

The system data shipped with the binary lives next to the executable, so
point `OPENMSX_SYSTEM_DATA` at it (otherwise openMSX falls back to
`/usr/share/openmsx`, which may be missing the `unapinet` extension):

```bash
OPENMSX_SYSTEM_DATA=~/Apps/openmsx/share \
  ~/Apps/openmsx/openmsx \
    -machine Philips_NMS_8250 \
    -ext Nextor213_IDE \
    -ext unapinet \
    -hda ~/msx/nextor_hd.dsk
```

If you prefer a global install:

```bash
sudo cp -r ~/Apps/openmsx/share /usr/local/share/openmsx
sudo cp ~/Apps/openmsx/openmsx /usr/local/bin/openmsx
```

### 4.5 Install the TSR onto the disk image

```bash
sudo apt-get install -y mtools         # if not already present
mcopy -o -i ~/msx/nextor_hd.dsk@@512 UNAPINET.COM ::
mdir   -i ~/msx/nextor_hd.dsk@@512 ::UNAPINET.COM
```

### 4.6 Capabilities and ports

The bridge uses the host's BSD socket API directly. No `CAP_NET_RAW` is
required for ICMP echo on Linux when the kernel allows unprivileged ICMP
sockets (the default on most modern distributions, controlled by
`/proc/sys/net/ipv4/ping_group_range`). If your distribution disables it,
ping support will return errors but TCP/UDP/DNS will still work.

---

## 5. Installing on macOS

### 5.1 Unpack the build

```bash
mkdir -p ~/Applications/openmsx && cd ~/Applications/openmsx
unzip ~/Downloads/openmsx-macos-arm64.zip
chmod +x openmsx
xattr -dr com.apple.quarantine .   # macOS Gatekeeper
```

The `xattr` step removes the *quarantine* attribute that the OS attaches
to anything downloaded from the internet. Without it, macOS will refuse
to launch the unsigned binary.

### 5.2 Install runtime libraries via Homebrew

```bash
brew install sdl2 sdl2_ttf freetype glew libpng libxml2 \
             tcl-tk libogg libvorbis libtheora
```

The build links against Homebrew's `tcl-tk`, which is keg-only. If the
binary fails to start with `dyld: Library not loaded ... libtcl8.6`,
add the Homebrew lib path explicitly:

```bash
export DYLD_LIBRARY_PATH="$(brew --prefix tcl-tk)/lib:${DYLD_LIBRARY_PATH:-}"
```

### 5.3 Provide ROMs

```bash
mkdir -p ~/Library/openMSX/share/systemroms
cp Philips_NMS_8250_BIOS.rom Philips_NMS_8250_SubROM.rom \
   Nextor-2.1.X.SunriseIDE.ROM ~/Library/openMSX/share/systemroms/
```

### 5.4 Run

```bash
OPENMSX_SYSTEM_DATA=~/Applications/openmsx/share \
  ~/Applications/openmsx/openmsx \
    -machine Philips_NMS_8250 \
    -ext Nextor213_IDE \
    -ext unapinet \
    -hda ~/msx/nextor_hd.dsk
```

### 5.5 Install the TSR onto the disk image

```bash
brew install mtools
mcopy -o -i ~/msx/nextor_hd.dsk@@512 UNAPINET.COM ::
mdir   -i ~/msx/nextor_hd.dsk@@512 ::UNAPINET.COM
```

### 5.6 Firewall

The first time openMSX opens an outbound socket, macOS may prompt with
*"Do you want the application 'openmsx' to accept incoming network
connections?"* — you can answer either way for outbound use; **Allow**
is required only if you intend to run a TCP server inside the MSX (TCP
passive mode).

---

## 6. Inside the emulator: enabling networking

Once openMSX is running with `-ext unapinet`, the bridge is live but the
MSX side still needs the TSR loaded.

At the Nextor / MSX-DOS 2 prompt:

```
A:\>UNAPINET
UnapiNet UNAPI TCP/IP installed (segment XX)
```

The TSR installs itself into a system mapper segment, hooks `EXTBIO`,
and stays resident until reboot. Any UNAPI TCP/IP client (`hget`,
`telnet`, `sntp`, `tftp`, `ping`, MSXgl-built games, etc.) will now
discover it and route its calls through the bridge.

Make `UNAPINET` autostart by adding it to `AUTOEXEC.BAT`:

```
A:\>EDIT AUTOEXEC.BAT
SET PATH=A:\;A:\BIN
UNAPINET
```

### Quick smoke tests

```
A:\>PING 8.8.8.8
A:\>SNTP pool.ntp.org
A:\>HGET http://example.com/index.html
A:\>TELNET sotanomsxbbs.org 23
```

If `PING` hangs or SNTP returns errors, see the Troubleshooting section
below.

---

## 7. Troubleshooting

| Symptom                                                     | Likely cause / fix                                                                                                                                |
|-------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `Couldn't load extension unapinet`                          | `share/extensions/unapinet.xml` is missing or `OPENMSX_SYSTEM_DATA` is wrong. Run with `-v` to see the search paths.                              |
| `UNAPINET.COM` errors on installation                       | The disk image was modified by openMSX while the emulator was running and `mcopy` updated a stale snapshot. Close the emulator before copying.    |
| `No TCP/IP UNAPI implementation found` from `hget`/`telnet` | The TSR was not loaded, or you launched a different DOS than the one where you ran `UNAPINET`. Re-run `UNAPINET` after each cold boot.            |
| `hget` hangs with the cursor blinking forever               | Old build of the TSR. The current build implements `TCPIP_WAIT` (fn 29). Rebuild and reinstall `UNAPINET.COM`.                                    |
| `PING` returns "TIMEOUT" but the host is reachable          | (Linux) `/proc/sys/net/ipv4/ping_group_range` excludes your user. Either widen the range (`echo "0 2147483647" | sudo tee ...`) or run as root.   |
| Random crashes or "7 halts" in MSXon multiplayer games      | TSR predates the `FN_TCP_STATE` fix. Reinstall the latest `UNAPINET.COM`.                                                                          |
| openMSX cannot find Tcl on macOS                            | Homebrew's `tcl-tk` is keg-only. Set `DYLD_LIBRARY_PATH` (see §5.2).                                                                              |
| Firewall blocks listening sockets                           | Allow inbound for `openmsx` on private networks. Required only for TCP passive mode (servers running inside the MSX).                              |

### Inspecting the bridge

The C++ device emits a debug log at `unapinet_debug.log` next to the
working directory when launched with `--ext unapinet` (the file is
truncated on each startup). Each I/O command and result is logged; this
is the first place to look when an MSX program misbehaves.

---

## 8. Notes

- **Save states do not persist sockets.** Loading a save state while a
  TCP connection is open will leave the MSX side seeing a half-open
  connection. Close TCP connections before saving state.
- **TLS is not supported.** Only `http://` works; `https://` URLs cannot
  be retrieved.
- **One UNAPI implementation per system.** If another extension also
  installs an UNAPI TCP/IP implementation, MSX programs will use the
  first one they find via `EXTBIO`. Disable the other extension or
  swap the order.

---

## 9. License

The openMSXnet sources are MIT-licensed (see [LICENSE](../LICENSE) when
present, otherwise the header in `unapinet/UnapiNet.cc`). openMSX itself
is GPL-2.0; the binary you download is therefore GPL-2.0. Source for
the exact build commit is available from the *Actions* run that produced
it.
