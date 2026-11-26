#!/usr/bin/env python3
"""pictos.py — SVG pictogram helper (template pictos + Lucide, ISC license).

- `list <dir>`: inventory of SVG pictos (name, viewBox).
- `lucide fetch <name>`: download one Lucide icon SVG into the local cache
  (unpkg lucide-static — ISC license, no attribution required).
- `lucide search <query>`: list matching Lucide icon names (network).
- `insert <pptx> <slide_index> <svg_or_png> <left_in> <top_in> [width_in]`:
  SVG is converted to PNG (cairosvg, cached) then inserted as a raster picture.
  (Native svgBlip embedding is future work — see report §6.)

Priority: template pictos first (already in charte), Lucide as complement
(captain decision Q1).
"""
import hashlib, os, sys

CACHE = os.path.expanduser("~/.cache/pptx-skill-pictos")
LUCIDE_CACHE = os.path.join(CACHE, "lucide")
LUCIDE_BASE = "https://unpkg.com/lucide-static@latest/icons"

def svg_to_png(svg_path, width=512, color=None):
    import cairosvg
    os.makedirs(CACHE, exist_ok=True)
    src = svg_path
    if color:
        # Lucide SVGs stroke with currentColor; bake the requested color in
        svg = open(svg_path, encoding="utf8").read().replace("currentColor", "#" + color.lstrip("#"))
        key = hashlib.sha1((svg + str(width)).encode()).hexdigest()[:16]
        src = os.path.join(CACHE, key + ".svg")
        open(src, "w", encoding="utf8").write(svg)
    key = hashlib.sha1((src + str(width)).encode()).hexdigest()[:16]
    png = os.path.join(CACHE, key + ".png")
    if not os.path.exists(png):
        cairosvg.svg2png(url=src, write_to=png, output_width=width, output_height=width)
    return png

def list_dir(d):
    import json, re
    inv = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".svg"):
            head = open(os.path.join(d, f), encoding="utf8", errors="ignore").read(2000)
            m = re.search(r'viewBox="([^"]*)"', head)
            inv.append({"file": f, "viewBox": m.group(1) if m else None})
    print(json.dumps(inv, indent=1))

def _lucide_cache_dir():
    os.makedirs(LUCIDE_CACHE, exist_ok=True)
    return LUCIDE_CACHE

def lucide_fetch(name):
    import urllib.request
    name = name.strip().lower().replace(" ", "-")
    os.makedirs(LUCIDE_CACHE, exist_ok=True)
    dest = os.path.join(LUCIDE_CACHE, name + ".svg")
    if not os.path.exists(dest):
        url = f"{LUCIDE_BASE}/{name}.svg"
        try:
            urllib.request.urlretrieve(url, dest)
        except Exception as e:
            if os.path.exists(dest):
                os.remove(dest)
            raise SystemExit(f"lucide fetch failed for {name!r}: {e}")
    print(dest)
    return dest

def lucide_search(query):
    import json, urllib.request
    url = "https://unpkg.com/lucide-static@latest/icons/?meta"
    try:
        meta = json.load(urllib.request.urlopen(url))
    except Exception as e:
        raise SystemExit(f"lucide search failed: {e}")
    names = sorted(e["path"].rsplit("/", 1)[-1][:-4]
                   for e in meta.get("files", [])
                   if e.get("type") == "image/svg+xml")
    q = query.lower()
    print(json.dumps([n for n in names if q in n], indent=1))

def insert(pptx, slide_index, path, left, top, width=None, color=None):
    from pptx import Presentation
    from pptx.util import Inches
    if path.endswith(".svg"):
        path = svg_to_png(path, color=color)
    prs = Presentation(pptx)
    slide = list(prs.slides)[int(slide_index)]
    kw = {"left": Inches(float(left)), "top": Inches(float(top))}
    if width:
        kw["width"] = Inches(float(width))
    slide.shapes.add_picture(path, **kw)
    prs.save(pptx)
    print(f"inserted {path} into slide {slide_index}")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "list":
        list_dir(sys.argv[2])
    elif cmd == "lucide":
        sub = sys.argv[2]
        if sub == "fetch":
            lucide_fetch(sys.argv[3])
        elif sub == "search":
            lucide_search(" ".join(sys.argv[3:]))
        else:
            print(__doc__)
    elif cmd == "insert":
        # insert <pptx> <slide> <path> <left> <top> [width] [colorRRGGBB]
        insert(*sys.argv[2:])
    else:
        print(__doc__)
