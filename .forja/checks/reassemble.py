#!/usr/bin/env python3
"""Reassemble msx/unapinet.asm with Nestor80 and verify output size.

Exits 0 if N80 succeeded and the .com file is plausible. Robust to
Windows cmd.exe quirks (running tools/N80.exe directly as the first
word of a shell command can fail to resolve).

The assembler version is pinned in ci/nestor80.version (single source
of truth, shared with .github/workflows/build.yml). If tools/N80.exe
is missing, it is bootstrapped from that pinned release via `gh`; if
present, its --version must match the pin."""
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
N80 = REPO / "tools" / "N80.exe"
ASM = REPO / "msx" / "unapinet.asm"
COM = REPO / "msx" / "unapinet.com"
VERSION_FILE = REPO / "ci" / "nestor80.version"


def pinned_tag() -> str:
    return VERSION_FILE.read_text(encoding="utf-8").strip()


def bootstrap_n80(tag: str) -> bool:
    """Download the pinned Nestor80 release and place N80.exe in tools/."""
    tools = REPO / "tools"
    tools.mkdir(exist_ok=True)
    print(f"[info] N80.exe missing; bootstrapping pinned Nestor80 {tag} via gh")
    r = subprocess.run(
        ["gh", "release", "download", tag, "--repo", "Konamiman/Nestor80",
         "--pattern", "N80_*_SelfContained_win-x64.zip",
         "--dir", str(tools), "--skip-existing"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        print(f"[fail] gh release download exit={r.returncode} "
              f"(is the GitHub CLI installed and authenticated?)")
        return False
    zips = sorted(tools.glob("N80_*_SelfContained_win-x64.zip"))
    if not zips:
        print("[fail] download reported success but no Nestor80 zip found")
        return False
    with zipfile.ZipFile(zips[-1]) as z:
        for name in z.namelist():
            if name.endswith("N80.exe"):
                N80.write_bytes(z.read(name))
                break
    return N80.exists()


tag = pinned_tag()
expected_version = tag.removeprefix("n80-v")

if not N80.exists():
    if not bootstrap_n80(tag):
        print(f"[fail] N80.exe not found at {N80} and bootstrap failed; "
              f"install Nestor80 {tag} there manually")
        sys.exit(1)

v = subprocess.run([str(N80), "--version"], capture_output=True, text=True)
actual_version = v.stdout.strip()
if actual_version != expected_version:
    print(f"[fail] tools/N80.exe is version '{actual_version}' but "
          f"ci/nestor80.version pins {tag} (= {expected_version}). "
          f"Delete tools/N80.exe and rerun to re-bootstrap.")
    sys.exit(1)

if not ASM.exists():
    print(f"[fail] unapinet.asm not found at {ASM}")
    sys.exit(1)

r = subprocess.run(
    [str(N80), str(ASM), str(COM), "--direct-output-write"],
    capture_output=True, text=True,
)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    print(f"[fail] N80 exit={r.returncode}")
    sys.exit(r.returncode)
if not COM.exists():
    print("[fail] N80 returned 0 but no .com written")
    sys.exit(1)

size = COM.stat().st_size
# Expected: ~2034 bytes after the DI-in-UNAPI_ENTRY fix.
# Sanity bounds: 1.5 KiB < size < 4 KiB.
if size < 1500 or size > 4096:
    print(f"[fail] suspicious .com size: {size} bytes")
    sys.exit(1)

print(f"[ok] reassembled {COM.name}: {size} bytes with Nestor80 {actual_version} (pinned {tag})")
sys.exit(0)
