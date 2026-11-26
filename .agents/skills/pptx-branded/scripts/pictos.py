#!/usr/bin/env python3
"""pictos.py — SVG pictogram helper (template pictos + Lucide set).

Subcommands:
- `list <dir>`: inventory of SVG pictos (name, viewBox).
- `lucide <icon-name>`: resolve (download-once, cache) a Lucide icon SVG;
  prints the cached file path. Lucide is ISC-licensed (license notice written
  next to the cache); it is the approved external fallback set (captain
  decision Q1) - always prefer template pictos when one fits.
- `insert <pptx> <slide_index> <svg_or_png|lucide:<name>> <left_in> <top_in>
  [width_in] [--color RRGGBB]`: SVG is recolored (optional) and converted to
  PNG (cairosvg, cached) then inserted as a raster picture. Native svgBlip
  embedding is future work - see design report section 6.
"""
import hashlib, os, re, sys

CACHE = os.path.expanduser("~/.cache/pptx-skill-pictos")
LUCIDE_URL = "https://unpkg.com/lucide-static@latest/icons/{name}.svg"
LUCIDE_LICENSE = "Lucide icons - ISC License - https://lucide.dev"


def _cache_path(kind, key):
    d = os.path.join(CACHE, kind)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, key)


def svg_to_png(svg_path, width=512, color=None):
    import cairosvg
    src = svg_path
    if color:
        svg_text = open(src, encoding="utf8").read()
        svg_text = re.sub(r"currentColor", f"#{color}", svg_text)
        key = hashlib.sha1((svg_path + str(width) + color).encode()).hexdigest()[:16]
        src = _cache_path("recolor", key + ".svg")
        with open(src, "w", encoding="utf8") as f:
            f.write(svg_text)
    key = hashlib.sha1((src + str(width)).encode()).hexdigest()[:16]
    png = _cache_path("conv", key + ".png")
    if not os.path.exists(png):
        cairosvg.svg2png(url=src, write_to=png, output_width=width, output_height=width)
    return png


def resolve_lucide(name):
    import urllib.request
    path = _cache_path("lucide", name + ".svg")
    if not os.path.exists(path):
        url = LUCIDE_URL.format(name=name)
        with urllib.request.urlopen(url, timeout=30) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
        lic = _cache_path("lucide", "LICENSE.txt")
        if not os.path.exists(lic):
            with open(lic, "w", encoding="utf8") as f:
                f.write(LUCIDE_LICENSE + "\n")
    return path


def list_dir(d):
    import json
    inv = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".svg"):
            head = open(os.path.join(d, f), encoding="utf8", errors="ignore").read(2000)
            m = re.search(r'viewBox="([^"]*)"', head)
            inv.append({"file": f, "viewBox": m.group(1) if m else None})
    print(json.dumps(inv, indent=1))


def insert(pptx, slide_index, path, left, top, width=None, color=None):
    from pptx import Presentation
    from pptx.util import Inches
    if path.startswith("lucide:"):
        path = resolve_lucide(path.partition(":")[2])
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


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd = argv[0]
    if cmd == "list":
        list_dir(argv[1])
    elif cmd == "lucide":
        print(resolve_lucide(argv[1]))
    elif cmd == "insert":
        args = argv[1:]
        color = None
        if "--color" in args:
            i = args.index("--color")
            color = args[i + 1]
            args = args[:i] + args[i + 2:]
        insert(*args, color=color)
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
