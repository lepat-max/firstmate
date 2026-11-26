#!/usr/bin/env python3
"""build_deck.py — deck-spec.json + template.pptx -> output.pptx

Contract (v1):
  deck-spec = {
    "template": "<path or name>",
    "output": "<path>",
    "slides": [
      {"entree": "layout:<layout name>",          # new slide from a real layout
       "placeholders": {"<idx>": "text", ...}},
      {"entree": "motif:<0-based index in template>",   # clone a template slide
       "zones": {"<shape name>": {"text": "new", "paras": [..]} | "new text", ...}},
      {"entree": "motif:<idx>", "delete": true}         # drop a cloned zone shape? (future)
    ],
    "notes": {"<slide#>": "speaker note"}   # 0-based
  }
Zone resolution inside a motif clone: a zone key matches a shape whose NAME equals
the key; if several share the name, the zone value may carry "match": "<text prefix>"
to disambiguate. The replacement keeps each paragraph and its first-run formatting
(paragraph count preserved; extra source paragraphs are blanked).
"""
import copy, hashlib, json, os, re, sys, time
from pptx import Presentation
from pptx.util import Inches

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
        else:
            for r in p.runs:
                r.text = ""

def resolve_shape(slide, key, match=None):
    cands = [sh for sh in slide.shapes if sh.name == key and sh.has_text_frame]
    if not cands:
        cands = [sh for sh in slide.shapes if sh.has_text_frame and sh.name == key]
    if match and len(cands) > 1:
        cands = [sh for sh in cands if sh.text_frame.text.strip().startswith(match)] or cands
    return cands[0] if cands else None

def find_layout(prs, name):
    for m in prs.slide_masters:
        for l in m.slide_layouts:
            if l.name == name:
                return l
    raise SystemExit(f"layout introuvable: {name!r}")

def main(spec_path):
    spec = json.load(open(spec_path))
    tpl = spec["template"]
    prs = Presentation(tpl)
    template_slides = list(prs.slides)  # motif source = slides already in the template copy

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
        note = (spec.get("notes") or {}).get(str(pos))
        if note:
            s.notes_slide.notes_text_frame.text = note

    # delete original template slides? No: spec may keep them. Optional "keep_template_slides"
    if not spec.get("keep_template_slides", False):
        sldIdLst = prs.slides._sldIdLst
        n_keep = len(spec["slides"])
        ids = list(sldIdLst)
        for sldId in ids[:len(ids) - n_keep]:
            sldIdLst.remove(sldId)
            prs.part.drop_rel(sldId.rId)

    out = spec["output"]
    prs.save(out)
    print(f"saved {out} ({len(spec['slides'])} slides cibles)")
    # deck manifest: mirror of the spec + per-slide hashes (input for update_deck.py)
    manifest = {
        "template": os.path.abspath(tpl),
        "output": os.path.abspath(out),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "slides": [],
    }
    for pos, entry in enumerate(spec["slides"]):
        body = {k: v for k, v in entry.items() if k != "pinned"}
        manifest["slides"].append({
            "index": pos,
            "entree": entry["entree"],
            "pinned": bool(entry.get("pinned", False)),
            "hash": hashlib.sha1(json.dumps(body, sort_keys=True).encode()).hexdigest(),
            "spec_entry": entry,
        })
    mpath = os.path.splitext(out)[0] + "-manifest.json"
    with open(mpath, "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    print(f"manifest -> {mpath}")
    # reopen check
    p2 = Presentation(out)
    print(f"reopened OK: {len(list(p2.slides))} slides")

if __name__ == "__main__":
    main(sys.argv[1])
