#!/usr/bin/env python3
"""Cross-check the wire protocol constants duplicated in the TSR and the
C++ device.

The opcodes exist twice by necessity: as EQUs in msx/unapinet.asm and as
constexpr in unapinet/UnapiNet.cc. A divergence only ever surfaced as a
runtime failure (commit c4d7620 fixed CMD_UDP_SEND being 0x29 on one side
and 0x0C on the other). This check makes the gate go red instead.

Protocol v2 widens the shared contract: the ERR_* codes now travel on the
wire verbatim (the status byte fronting every reply), so they are
cross-checked too, and the DETECT acceptance bytes (magic, version) live
as defaulted members of DetectResult in unapinet/UnapiNetWire.hh - parsed
from there, since the C++ deliberately has no separate constants for them.

Every name present on BOTH sides must have the same value. One-sided
names are reported as info, not failure. A minimum-pairs floor guards
against a silent parse regression faking green."""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASM = REPO / "msx" / "unapinet.asm"
CC = REPO / "unapinet" / "UnapiNet.cc"
WIRE = REPO / "unapinet" / "UnapiNetWire.hh"

# Only these families are wire-protocol contracts shared by both sides.
PREFIXES = ("CMD_", "ERR_", "DETECT_")

MIN_PAIRS = 25  # today there are 30; a big drop means the parser broke


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


def parse_wire_detect(path: Path) -> dict[str, int]:
    """DETECT magic/version are defaulted members of DetectResult."""
    text = path.read_text(encoding="utf-8", errors="replace")
    out = {}
    for asm_name, member in (("DETECT_MAGIC", "magic"), ("DETECT_VER", "version")):
        m = re.search(
            rf"uint8_t\s+{member}\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*;", text)
        if m:
            out[asm_name] = int(m.group(1), 0)
    return out


asm = parse_asm(ASM)
cc = parse_cc(CC) | parse_wire_detect(WIRE)

pairs = 0
mismatches = []
for asm_name, asm_val in sorted(asm.items()):
    if asm_name not in cc:
        continue
    pairs += 1
    if cc[asm_name] != asm_val:
        mismatches.append(
            f"{asm_name}: asm=0x{asm_val:02X} vs C++=0x{cc[asm_name]:02X}")

only_asm = [n for n in sorted(asm) if n not in cc]
only_cc = [n for n in sorted(cc) if n not in asm]
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
