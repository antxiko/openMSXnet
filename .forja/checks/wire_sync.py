#!/usr/bin/env python3
"""Cross-check the wire protocol constants duplicated in the TSR and the
C++ device.

The opcodes/status bytes exist twice by necessity: as EQUs in
msx/unapinet.asm and as constexpr in unapinet/UnapiNet.cc. A divergence
only ever surfaced as a runtime failure (commit c4d7620 fixed
CMD_UDP_SEND being 0x29 on one side and 0x0C on the other). This check
makes the gate go red instead.

Every name present on BOTH sides (after aliasing) must have the same
value. One-sided names are reported as info, not failure (the TSR
legitimately does not use CMD_QUERY_CAP yet). A minimum-pairs floor
guards against a silent parse regression faking green."""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASM = REPO / "msx" / "unapinet.asm"
CC = REPO / "unapinet" / "UnapiNet.cc"

# Same constant, different name on each side.
ALIASES = {"PING_MAGIC": "MAGIC"}  # asm name -> C++ name

# Only these families are wire-protocol contracts shared by both sides.
PREFIXES = ("CMD_", "STATUS_", "PING_MAGIC", "MAGIC")

MIN_PAIRS = 15  # today there are 22; a big drop means the parser broke


def parse_asm_value(tok: str) -> int:
    tok = tok.strip().rstrip(";").strip()
    if tok.lower().endswith("h"):
        return int(tok[:-1], 16)
    if tok.lower().startswith("0x"):
        return int(tok, 16)
    return int(tok, 10)


def parse_asm(path: Path) -> dict[str, int]:
    out = {}
    rx = re.compile(r"^(\w+):?\s+equ\s+(\S+)", re.IGNORECASE)
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = rx.match(line.strip())
        if not m:
            continue
        name = m.group(1)
        if not name.startswith(PREFIXES):
            continue
        try:
            out[name] = parse_asm_value(m.group(2))
        except ValueError:
            print(f"[fail] cannot parse asm value for {name}: {m.group(2)!r}")
            sys.exit(1)
    return out


def parse_cc(path: Path) -> dict[str, int]:
    out = {}
    rx = re.compile(
        r"constexpr\s+uint8_t\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*;")
    for m in rx.finditer(path.read_text(encoding="utf-8", errors="replace")):
        name = m.group(1)
        if not name.startswith(PREFIXES):
            continue
        out[name] = int(m.group(2), 0)
    return out


asm = parse_asm(ASM)
cc = parse_cc(CC)

pairs = 0
mismatches = []
for asm_name, asm_val in sorted(asm.items()):
    cc_name = ALIASES.get(asm_name, asm_name)
    if cc_name not in cc:
        continue
    pairs += 1
    if cc[cc_name] != asm_val:
        mismatches.append(
            f"{asm_name}: asm=0x{asm_val:02X} vs C++ {cc_name}=0x{cc[cc_name]:02X}")

only_asm = [n for n in sorted(asm) if ALIASES.get(n, n) not in cc]
cc_matched = {ALIASES.get(n, n) for n in asm}
only_cc = [n for n in sorted(cc) if n not in cc_matched]
if only_asm:
    print(f"[info] asm-only names (no C++ counterpart): {', '.join(only_asm)}")
if only_cc:
    print(f"[info] C++-only names (TSR does not use them): {', '.join(only_cc)}")

if pairs < MIN_PAIRS:
    print(f"[fail] only {pairs} comparable pairs found (expected >= {MIN_PAIRS}); "
          f"a parser or file-layout change broke this check")
    sys.exit(1)

print(f"Ran {pairs} tests")
if mismatches:
    for msg in mismatches:
        print(f"[fail] wire divergence: {msg}")
    print(f"{pairs - len(mismatches)} passed, {len(mismatches)} failed")
    sys.exit(1)

print(f"{pairs} passed")
print(f"[ok] asm and C++ agree on all {pairs} shared wire constants")
sys.exit(0)
