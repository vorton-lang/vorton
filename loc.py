#!/usr/bin/env python3
"""vorton-lang lines-of-code counter. Usage: python loc.py [dir...]  (default: compiler/ std/)"""

import sys
from pathlib import Path

dirs = sys.argv[1:] or ["compiler", "std"]

total = blank = comment = code = 0

header = f"{'File':<40s} {'Total':>8s} {'Blank':>8s} {'Comment':>8s} {'Code':>8s}"
sep    = f"{'----':<40s} {'-----':>8s} {'-----':>8s} {'-------':>8s} {'----':>8s}"
print(header)
print(sep)

for d in dirs:
    for f in sorted(Path(d).glob("*.vorton")):
        if not f.is_file():
            continue
        text = f.read_text(encoding="utf-8")
        lines = text.splitlines()
        ft = len(lines)
        fb = sum(1 for l in lines if l.strip() == "")
        fc = sum(1 for l in lines if l.strip().startswith("//"))
        fcode = ft - fb - fc
        print(f"{str(f):<40s} {ft:>8d} {fb:>8d} {fc:>8d} {fcode:>8d}")
        total += ft
        blank += fb
        comment += fc
        code += fcode

print(sep)
print(f"{'TOTAL':<40s} {total:>8d} {blank:>8d} {comment:>8d} {code:>8d}")
