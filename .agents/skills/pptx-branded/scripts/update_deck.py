#!/usr/bin/env python3
"""update_deck.py — regenerate an existing branded deck from a new deck-spec.

Rule (captain decision Q3): every slide NOT marked "pinned" in the deck-spec is
regenerated on update; manual edits survive only on pinned slides.

Mechanics (v1):
- "keep"    : slide unchanged between old manifest and new spec -> left untouched.
- "pin_keep": slide changed but pinned -> left untouched, warning printed.
- "regen"   : slide changed and not pinned -> re-cloned in place from its own
              current slide (same package, media rels preserved) then the new
              zones / placeholders are applied.
- "add"     : new slide beyond the old deck -> re-cloned in place from another
              deck slide with the same motif; if none exists, a full rebuild from
              the template is performed when NO slide is pinned anywhere, else
              the update aborts (a cross-package clone could corrupt the deck).
- "delete"  : old slides beyond the new spec -> dropped (orphans are not saved).

Usage: update_deck.py <deck.pptx> <new-deck-spec.json>
The generation manifest is read from `<deck.pptx>.manifest.json` and rewritten.
"""
import copy, datetime, hashlib, json, os, sys
from pptx import Presentation


def _load_build_module():
    here = os.path.dirname(os.path.abspath(__file__))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "pptx_branded_build_deck", os.path.join(here, "build_deck.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

_B = _load_build_module()
clone_slide = _B.clone_slide
set_zone = _B.set_zone
resolve_shape = _B.resolve_shape
find_layout = _B.find_layout


def norm(entry):
    return json.dumps(
        {"entree": entry.get("entree"),
         "zones": entry.get("zones") or {},
         "placeholders": entry.get("placeholders") or {},
         "notes": entry.get("notes")},
        sort_keys=True, ensure_ascii=False)


def plan_update(old_slides, new_spec_slides):
    """Pure diff: returns [{'pos', 'old_pos', 'action', 'reason'}...] in new order."""
    actions = []
    for i, entry in enumerate(new_spec_slides):
        if i < len(old_slides):
            old = old_slides[i]
            if old.get("entree") != entry.get("entree"):
                action = "pin_keep" if old.get("pinned") else "regen"
                reason = "entree changed"
            elif norm(old) != norm(entry):
                action = "pin_keep" if old.get("pinned") else "regen"
                reason = "content changed"
            else:
                action, reason = "keep", "identical"
            actions.append({"pos": i, "old_pos": i, "action": action, "reason": reason})
        else:
            actions.append({"pos": i, "old_pos": None, "action": "add", "reason": "new slide"})
    for j in range(len(new_spec_slides), len(old_slides)):
        actions.append({"pos": None, "old_pos": j, "action": "delete", "reason": "removed from spec"})
    return actions


def apply_entry(slide, entry, template_slides=None):
    """Apply zones (motif) or placeholder texts (layout) onto an already-cloned slide."""
    kind = entry["entree"].partition(":")[0]
    if kind == "layout":
        for idx, text in (entry.get("placeholders") or {}).items():
            for sh in slide.placeholders:
                if sh.placeholder_format.idx == int(idx):
                    sh.text_frame.text = text
                    break
    for key, zone in (entry.get("zones") or {}).items():
        match = zone.get("match") if isinstance(zone, dict) else None
        sh = resolve_shape(slide, key, match)
        if sh is None:
            print(f"WARN: zone {key!r} introuvable")
            continue
        set_zone(sh, zone)
    note = entry.get("notes")
    if note:
        slide.notes_slide.notes_text_frame.text = note


def clone_in_place(prs, source_slide):
    """Clone a slide of THIS deck (same package: media rels stay valid)."""
    return clone_slide(prs, source_slide)


def place_at(prs, new_slide, pos):
    """Move the freshly appended slide's sldId to index pos."""
    lst = prs.slides._sldIdLst
    els = list(lst)
    new_el = els[-1]
    lst.remove(new_el)
    lst.insert(pos, new_el)


def drop_slide_at(prs, pos):
    lst = prs.slides._sldIdLst
    el = list(lst)[pos]
    lst.remove(el)
    prs.part.drop_rel(el.rId)


def rebuild_full(new_spec, out_path):
    """Full regeneration from the template via build_deck (same contract)."""
    spec = dict(new_spec)
    spec["output"] = out_path
    spec_path = out_path + ".update-spec.json"
    with open(spec_path, "w", encoding="utf8") as f:
        json.dump(spec, f, ensure_ascii=False)
    _B.main(spec_path)
    os.remove(spec_path)


def main(deck_path, spec_path):
    new_spec = json.load(open(spec_path))
    manifest_path = deck_path + ".manifest.json"
    if not os.path.exists(manifest_path):
        raise SystemExit(f"manifest introuvable: {manifest_path} (deck genere par build_deck ?)")
    manifest = json.load(open(manifest_path))
    old_slides = manifest["slides"]
    actions = plan_update(old_slides, new_spec["slides"])
    for a in actions:
        print(f"slide {a['pos'] if a['pos'] is not None else '-'}: {a['action']} ({a['reason']})")

    regen_or_add = [a for a in actions if a["action"] in ("regen", "add")]
    pinned = [s for s in old_slides if s.get("pinned")]

    # adds without an in-place motif source: full rebuild when nothing is pinned
    motif_index = {i: e.get("motif") for i, e in enumerate(new_spec["slides"])}
    need_rebuild = False
    for a in regen_or_add:
        if a["action"] == "add":
            motif = motif_index[a["pos"]]
            if not any(m == motif for m in
                       [old_slides[i]["motif"] for i in range(min(a["pos"], len(old_slides)))
                        if old_slides[i].get("motif") is not None]):
                if pinned:
                    raise SystemExit(
                        f"impossible d'ajouter le motif {motif} sans perte: slides pinned presentes. "
                        "Regenerer tout le deck (build_deck) apres avoir decide des slides pinned.")
                need_rebuild = True

    if need_rebuild:
        print("rebuild complet depuis le template (aucune slide pinned)")
        rebuild_full(new_spec, deck_path)
        return

    prs = Presentation(deck_path)
    deck_slides = list(prs.slides)
    motif_source = {}
    for i, s in enumerate(old_slides):
        if s.get("motif") is not None:
            motif_source.setdefault(s["motif"], i)

    for a in actions:
        if a["action"] == "regen":
            i = a["pos"]
            entry = new_spec["slides"][i]
            src = deck_slides[i]
            new = clone_in_place(prs, src)
            apply_entry(new, entry)
            place_at(prs, new, i)
            drop_slide_at(prs, i + 1)  # old slide shifted right by the insert
            deck_slides[i] = new
        elif a["action"] == "pin_keep":
            print(f"WARN: slide {a['pos']} pinned: modifications ignorees (retouches manuelles conservees)")
        elif a["action"] == "add":
            i = a["pos"]
            motif = motif_index[i]
            src_idx = motif_source.get(motif)
            if src_idx is None:
                raise SystemExit(f"motif {motif} absent du deck: rebuild complet requis")
            src = deck_slides[src_idx]
            new = clone_in_place(prs, src)
            apply_entry(new, new_spec["slides"][i])
            place_at(prs, new, i)
            deck_slides.insert(i, new)
            motif_source = {m: (idx + 1 if idx >= i else idx) for m, idx in motif_source.items()}
            motif_source.setdefault(motif, i)
        elif a["action"] == "delete":
            drop_slide_at(prs, a["old_pos"])
            deck_slides.pop(a["old_pos"])
            motif_source = {m: (idx - 1 if idx > a["old_pos"] else idx) for m, idx in motif_source.items()}

    manifest = {
        "template": new_spec.get("template", manifest.get("template")),
        "template_sha1": (hashlib.sha1(open(new_spec["template"], "rb").read()).hexdigest()
                          if new_spec.get("template") and os.path.exists(new_spec["template"])
                          else manifest.get("template_sha1")),
        "generated_at": manifest.get("generated_at"),
        "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "slides": [],
    }
    for i, entry in enumerate(new_spec["slides"]):
        s = list(prs.slides)[i]
        manifest["slides"].append({
            "pos": i,
            "entree": entry.get("entree"),
            "motif": int(entry["entree"].partition(":")[2]) if entry["entree"].startswith("motif:") else None,
            "layout": s.slide_layout.name,
            "zones": entry.get("zones") or {},
            "placeholders": entry.get("placeholders") or {},
            "pinned": bool(entry.get("pinned", False)),
            "notes": entry.get("notes"),
        })
    with open(manifest_path, "w", encoding="utf8") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    prs.save(deck_path)
    print(f"saved {deck_path} ({len(new_spec['slides'])} slides)")
    print(f"manifest -> {manifest_path}")
    p2 = Presentation(deck_path)
    print(f"reopened OK: {len(list(p2.slides))} slides")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
