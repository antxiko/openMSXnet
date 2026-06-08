#!/usr/bin/env python3
"""IE invariant for msx/unapinet.asm — exit 0 if invariant holds, 1 otherwise.

The TSR's UNAPI_ENTRY does a global `di` to make port transactions atomic.
That is only safe iff every `ret` inside a runtime function (FN_*) is
preceded by an `ei` somewhere in the few preceding instructions, so the
caller sees IE=1 restored on return.

Checks:
  1) `di` is present near the top of UNAPI_ENTRY (the global protection).
  2) Every `ret` instruction inside a FN_* function has an `ei` within
     a small lookback window (covers patterns like
     `ei; ret`,
     `ei; halt; xor a; ret` (FN_WAIT),
     `ei; ret z; ld a,...; ret` (FN_TCP_SEND post-fix)).

Pre-dispatcher rets (installer helpers, EXTBIO chain, dispatcher
trampoline, TOUPPER) live outside FN_* labels and are intentionally
excluded — they run with the caller's IE since the global `di` has not
fired yet (or the trampoline is a `jp`-equivalent, not a `ret` to the
client).
"""
import re
import sys
from pathlib import Path

ASM = Path(__file__).resolve().parents[2] / "msx" / "unapinet.asm"
if not ASM.exists():
    print(f"[fail] cannot find {ASM}")
    sys.exit(2)

lines = ASM.read_text(errors="replace").splitlines()

# --- 1) `di` near top of UNAPI_ENTRY ------------------------------------------
entry_idx = next((i for i, l in enumerate(lines) if re.match(r"^UNAPI_ENTRY:\s*$", l)), None)
if entry_idx is None:
    print("[fail] UNAPI_ENTRY: label not found")
    sys.exit(1)

di_window = 8
di_found = False
for j in range(entry_idx + 1, min(entry_idx + 1 + di_window, len(lines))):
    code = lines[j].split(";")[0].strip()
    if re.match(r"^di(\s|$)", code):
        di_found = True
        break
if not di_found:
    print(f"[fail] no `di` within {di_window} lines after UNAPI_ENTRY (line {entry_idx + 1})")
    sys.exit(1)

# --- 2) Every ret inside FN_* protected by an `ei` in lookback ----------------
# Build a list of every top-level label (not local `.xxx:`); these mark
# the boundary between sections. A FN_* function body extends to the
# *next* top-level label, whatever its name — that closes the function
# cleanly even when the next section is TOUPPER or similar utilities.
top_label_re = re.compile(r"^([A-Z_][A-Z_0-9]*):\s*(;.*)?$")
top_labels = []
for i, l in enumerate(lines):
    if top_label_re.match(l):
        name = top_label_re.match(l).group(1)
        top_labels.append((i, name))

fn_ranges = []
for k, (i, name) in enumerate(top_labels):
    if not name.startswith("FN_"):
        continue
    end = top_labels[k + 1][0] if k + 1 < len(top_labels) else len(lines)
    fn_ranges.append((i, end, name))

if not fn_ranges:
    print("[fail] no FN_* labels found")
    sys.exit(1)

ret_re = re.compile(r"^ret(\b|$)")  # ret, ret z, ret nz, ret c, etc.
ei_re = re.compile(r"^ei(\b|$)")

LOOKBACK = 8
violations = []
total_rets = 0
for start, end, name in fn_ranges:
    for i in range(start, end):
        code = lines[i].split(";")[0].strip()
        if not ret_re.match(code):
            continue
        total_rets += 1
        # walk back for an `ei` within LOOKBACK lines, stay within FN_* body
        found = False
        for j in range(max(start, i - LOOKBACK), i):
            prev = lines[j].split(";")[0].strip()
            if ei_re.match(prev):
                found = True
                break
        if not found:
            violations.append((i + 1, name, code))

if violations:
    print(f"[fail] IE invariant violations ({len(violations)} of {total_rets} rets):")
    for ln, fn, code in violations:
        print(f"  L{ln} in {fn}: '{code}'")
    sys.exit(1)

passed = total_rets + 1  # +1 for the `di` presence check in UNAPI_ENTRY
print(f"[ok] IE invariant: di present in UNAPI_ENTRY, {total_rets} rets across {len(fn_ranges)} runtime functions all covered by ei (lookback {LOOKBACK}).")
# Conteo de tests para el forensic-gate runner (busca uno de: 'Ran N test',
# 'N passed', 'N passing', 'collected N item', 'Tests: N passed').
print(f"Ran {passed} tests")
print(f"{passed} passed")
sys.exit(0)
