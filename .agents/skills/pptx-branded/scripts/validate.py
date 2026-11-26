#!/usr/bin/env python3
"""validate.py — checks a generated pptx and renders it.

Usage: validate.py <file.pptx> [--render-dir DIR]
1. Reopen with python-pptx (structure sane, slide count).
2. Static checks: no leftover placeholder prompt text, no client markers list (optional --forbid token file).
3. LibreOffice headless -> PDF, page count must equal slide count.
4. Optional PNG render of every page (pdftoppm) for visual inspection.
"""
import re, shutil, subprocess, sys, os, tempfile
from pptx import Presentation

RESIDUE_PATTERNS = [
    r"Cliquez pour modifier", r"Modifiez le style", r"Espace réservé", r"Titre 3\b",
]

SOFFICE_CANDIDATES = [
    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    "/usr/bin/soffice", "/usr/local/bin/soffice",
]


def soffice():
    found = shutil.which("soffice")
    if found:
        return found
    for c in SOFFICE_CANDIDATES:
        if os.path.exists(c):
            return c
    raise SystemExit("LibreOffice introuvable (binaire soffice)")

def main(path, render_dir=None, forbid=None):
    fails = []
    prs = Presentation(path)
    n = len(list(prs.slides))
    print(f"reopen OK: {n} slides")
    for i, s in enumerate(prs.slides):
        for sh in s.shapes:
            if sh.has_text_frame:
                t = sh.text_frame.text
                for pat in RESIDUE_PATTERNS:
                    if re.search(pat, t):
                        fails.append(f"slide {i}: résidu {pat!r} dans {sh.name!r}")
                if forbid:
                    for tok in forbid:
                        if tok in t:
                            fails.append(f"slide {i}: marqueur interdit {tok!r}")
    if fails:
        for f in fails:
            print("FAIL", f)
        sys.exit(1)
    print("static checks OK")

    out = render_dir or tempfile.mkdtemp(prefix="pptx-validate-")
    pdf = os.path.join(out, os.path.splitext(os.path.basename(path))[0] + ".pdf")
    r = subprocess.run([soffice(), "--headless",
                        "--convert-to", "pdf", "--outdir", out, path],
                       capture_output=True, text=True, timeout=300)
    if not os.path.exists(pdf):
        print("FAIL LibreOffice:", r.stderr[-400:])
        sys.exit(1)
    pages = len(re.findall(rb"/Type\s*/Page[^s]", open(pdf, "rb").read()))
    if pages != n:
        print(f"FAIL pages: {pages} != {n} slides")
        sys.exit(1)
    print(f"render OK: PDF {pages} pages -> {pdf}")
    print("VALID")

if __name__ == "__main__":
    args = sys.argv[1:]
    path = args[0]
    render_dir = None
    forbid = None
    if "--render-dir" in args:
        render_dir = args[args.index("--render-dir") + 1]
    if "--forbid-file" in args:
        forbid = [l.strip() for l in open(args[args.index("--forbid-file") + 1]) if l.strip()]
    main(path, render_dir, forbid)
