#!/usr/bin/env python3
"""build_deck.py — deck-spec.json + template.pptx -> output.pptx

Contract (v1):
  deck-spec = {
    "template": "<path or name>",
    "output": "<path>",
    "slides": [
      {"entree": "layout:<layout name>",          # new slide from a real layout
       "placeholders": {"<idx>": "text", ...},
       "pinned": true},                           # optional: survive updates as-is
      {"entree": "motif:<0-based index in template>",   # clone a template slide
       "zones": {"<shape name>": {"text": "new", "paras": [..]} | "new text", ...},
       "pinned": true}
    ],
    "notes": {"<slide#>": "speaker note"}   # 0-based
  }
Zone resolution inside a motif clone: a zone key matches a shape whose NAME equals
the key; if several share the name, the zone value may carry "match": "<text prefix>"
to disambiguate. The replacement keeps each paragraph and its first-run formatting
(paragraph count preserved; extra source paragraphs are blanked).

Output: the deck plus `<output>.manifest.json`, the generation record consumed by
update_deck.py (per-slide entree, zones, layout, pinned flag).
"""
import copy, datetime, hashlib, json, os, sys
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.util import Pt


def clone_slide(prs, slide):
    # keep the SOURCE layout: placeholders inherit formatting from it
    new = prs.slides.add_slide(slide.slide_layout)
    for sh in list(new.shapes):
        sh._element.getparent().remove(sh._element)
    for rId, rel in slide.part.rels.items():
        if rel.reltype.endswith("/image"):
            new.part.rels.get_or_add(rel.reltype, rel._target)
    for sh in slide.shapes:
        new.shapes._spTree.append(copy.deepcopy(sh._element))
    return new


def set_zone(shape, spec):
    if isinstance(spec, str):
        spec = {"text": spec}
    tf = shape.text_frame
    paras = tf.paragraphs
    new_text = spec.get("text")
    lines = spec.get("paras")
    if lines is None and new_text is not None:
        lines = [new_text]
    if lines is None:
        return
    color = spec.get("color")
    size = spec.get("size")
    # write line i into paragraph i (first run keeps formatting); blank the rest
    for i, p in enumerate(paras):
        if i < len(lines):
            line = lines[i]
            if p.runs:
                p.runs[0].text = line
                for r in p.runs[1:]:
                    r.text = ""
            else:
                p.text = line
            if color and p.runs:
                p.runs[0].font.color.rgb = RGBColor.from_string(color)
            if size and p.runs:
                p.runs[0].font.size = Pt(int(size))
        else:
            for r in p.runs:
                r.text = ""


def resolve_shape(slide, key, match=None):
    cands = [sh for sh in slide.shapes if sh.name == key and sh.has_text_frame]
    if match and len(cands) > 1:
        cands = [sh for sh in cands if sh.text_frame.text.strip().startswith(match)] or cands
    return cands[0] if cands else None


def find_layout(prs, name):
    for m in prs.slide_masters:
        for l in m.slide_layouts:
            if l.name == name:
                return l
    raise SystemExit(f"layout introuvable: {name!r}")


def slide_summary(slide, entry):
    return {
        "pos": None,  # filled by caller
        "entree": entry.get("entree"),
        "motif": int(entry["entree"].partition(":")[2]) if entry["entree"].startswith("motif:") else None,
        "layout": slide.slide_layout.name,
        "zones": entry.get("zones") or {},
        "placeholders": entry.get("placeholders") or {},
        "pinned": bool(entry.get("pinned", False)),
        "notes": entry.get("notes"),
    }


def main(spec_path):
    spec = json.load(open(spec_path))
    tpl = spec["template"]
    prs = Presentation(tpl)
    template_slides = list(prs.slides)  # motif source = slides already in the template copy

    manifest = {
        "template": os.path.abspath(tpl),
        "template_sha1": hashlib.sha1(open(tpl, "rb").read()).hexdigest(),
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "slides": [],
    }

    for pos, entry in enumerate(spec["slides"]):
        kind, _, ref = entry["entree"].partition(":")
        if kind == "layout":
            lay = find_layout(prs, ref)
            prs.slides.add_slide(lay)
            s = prs.slides[-1]
            for idx, text in (entry.get("placeholders") or {}).items():
                idx = int(idx)
                for sh in s.placeholders:
                    if sh.placeholder_format.idx == idx:
                        sh.text_frame.text = text
                        break
        elif kind == "motif":
            src = template_slides[int(ref)]
            s = clone_slide(prs, src)
            for key, zone in (entry.get("zones") or {}).items():
                match = zone.get("match") if isinstance(zone, dict) else None
                sh = resolve_shape(s, key, match)
                if sh is None:
                    print(f"WARN slide {pos}: zone {key!r} introuvable")
                    continue
                set_zone(sh, zone)
        else:
            raise SystemExit(f"entree inconnue: {entry['entree']!r}")
        note = (spec.get("notes") or {}).get(str(pos), entry.get("notes"))
        if note:
            s.notes_slide.notes_text_frame.text = note
        summary = slide_summary(s, entry)
        summary["pos"] = pos
        summary["notes"] = note
        manifest["slides"].append(summary)

    # drop the untouched template slides unless the spec asks to keep them
    if not spec.get("keep_template_slides", False):
        sldIdLst = prs.slides._sldIdLst
        n_keep = len(spec["slides"])
        ids = list(sldIdLst)
        for sldId in ids[:len(ids) - n_keep]:
            sldIdLst.remove(sldId)
            prs.part.drop_rel(sldId.rId)

    out = spec["output"]
    prs.save(out)
    manifest_path = out + ".manifest.json"
    with open(manifest_path, "w", encoding="utf8") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    print(f"saved {out} ({len(spec['slides'])} slides cibles)")
    print(f"manifest -> {manifest_path}")
    # reopen check
    p2 = Presentation(out)
    print(f"reopened OK: {len(list(p2.slides))} slides")


if __name__ == "__main__":
    main(sys.argv[1])
