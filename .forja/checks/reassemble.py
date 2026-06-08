#!/usr/bin/env python3
"""Reassemble msx/unapinet.asm with Nestor80 and verify output size.

Exits 0 if N80 succeeded and the .com file is plausible. Robust to
Windows cmd.exe quirks (running tools/N80.exe directly as the first
word of a shell command can fail to resolve)."""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
N80 = REPO / "tools" / "N80.exe"
ASM = REPO / "msx" / "unapinet.asm"
COM = REPO / "msx" / "unapinet.com"

if not N80.exists():
    print(f"[fail] N80.exe not found at {N80}")
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

print(f"[ok] reassembled {COM.name}: {size} bytes")
sys.exit(0)
