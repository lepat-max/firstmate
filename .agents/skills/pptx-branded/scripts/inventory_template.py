#!/usr/bin/env python3
"""inventory_template.py — template.pptx -> template-manifest.json

Manifest: layouts (name, placeholders with idx/type), slides (index, layout,
shapes with name/type/position/text prefix), media (images, svg pictos), theme
palette. This is the file the agent reads to choose entrées and zones.
"""
import json, re, sys, zipfile
from pptx import Presentation
from pptx.util import Emu

def main(path, out):
    prs = Presentation(path)
    manifest = {"template": path, "size_emu": [prs.slide_width, prs.slide_height],
                "layouts": [], "slides": [], "media": {}}
    for m in prs.slide_masters:
        for lay in m.slide_layouts:
            manifest["layouts"].append({
                "name": lay.name,
                "placeholders": [{"idx": p.placeholder_format.idx,
                                  "type": str(p.placeholder_format.type).split(" ")[0],
                                  "name": p.name} for p in lay.placeholders]})
    for i, s in enumerate(prs.slides):
        shapes = []
        for sh in s.shapes:
            entry = {"name": sh.name, "type": str(sh.shape_type).split(" ")[0],
                     "pos_in": [round(Emu(sh.left or 0).inches, 2), round(Emu(sh.top or 0).inches, 2)],
                     "size_in": [round(Emu(sh.width or 0).inches, 2), round(Emu(sh.height or 0).inches, 2)]}
            if sh.is_placeholder:
                entry["placeholder_idx"] = sh.placeholder_format.idx
            if sh.has_text_frame and sh.text_frame.text.strip():
                entry["text"] = sh.text_frame.text.strip()[:120]
            if sh.has_table:
                entry["table"] = [len(sh.table.rows), len(sh.table.columns)]
            shapes.append(entry)
        manifest["slides"].append({"index": i, "layout": s.slide_layout.name, "shapes": shapes})
    z = zipfile.ZipFile(path)
    manifest["media"] = {"svg": sorted(n.split("/")[-1] for n in z.namelist() if n.endswith(".svg")),
                         "images": sorted(n.split("/")[-1] for n in z.namelist()
                                          if re.search(r"media/image\d+\.(png|jpe?g|emf)$", n))}
    theme = z.read("ppt/theme/theme1.xml").decode("utf8", "ignore")
    manifest["theme"] = {
        "colors": {m.group(1): m.group(2) for m in
                   re.finditer(r"<a:(\w+)><a:srgbClr val=\"([0-9A-Fa-f]{6})\"", theme)},
        "fonts": {m.group(1): m.group(2) for m in
                  re.finditer(r"<a:(majorFont|minorFont)><a:latin typeface=\"([^\"]*)\"", theme)},
    }
    json.dump(manifest, open(out, "w"), indent=1, ensure_ascii=False)
    print(f"manifest -> {out} ({len(manifest['layouts'])} layouts, {len(manifest['slides'])} slides)")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
