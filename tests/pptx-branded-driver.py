#!/usr/bin/env python3
"""Driver for tests/pptx-branded.test.sh.

Runs one scenario against the real pptx-branded scripts with synthetic pptx
fixtures. Behavior is exercised through the scripts' public interfaces (module
functions and CLI), never by asserting on their source text.

Usage: pptx-branded-driver.py <scenario> <workdir> <scripts-dir>
"""
import copy
import importlib.util
import json
import os
import subprocess
import sys

from pptx import Presentation
from pptx.util import Inches, Pt


def load_module(scripts, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(scripts, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def expect(cond, msg):
    if not cond:
        raise SystemExit(f"ASSERT FAIL: {msg}")


def build_template(path):
    """Synthetic 3-slide template: cover, KPI pattern, free zone."""
    prs = Presentation()
    s0 = prs.slides.add_slide(prs.slide_layouts[6])
    t = s0.shapes.add_textbox(Inches(1), Inches(1), Inches(4), Inches(1))
    t.name = "Titre 1"
    t.text_frame.text = "Titre du modele"
    d = s0.shapes.add_textbox(Inches(1), Inches(2), Inches(2), Inches(0.5))
    d.name = "Date 1"
    d.text_frame.text = "JJ/MM/AAAA"

    s1 = prs.slides.add_slide(prs.slide_layouts[6])
    c1 = s1.shapes.add_textbox(Inches(1), Inches(1), Inches(2), Inches(1))
    c1.name = "Carte 1"
    c1.text_frame.text = "Valeur A\nLegende A"
    c2 = s1.shapes.add_textbox(Inches(4), Inches(1), Inches(2), Inches(1))
    c2.name = "Carte 2"
    c2.text_frame.text = "Valeur B\nLegende B"

    s2 = prs.slides.add_slide(prs.slide_layouts[6])
    z = s2.shapes.add_textbox(Inches(1), Inches(1), Inches(3), Inches(1))
    z.name = "Zone 1"
    z.text_frame.text = "Brut"

    prs.save(path)
    return path


def add_picture(path, slide_index=1, name=None):
    from PIL import Image
    png = path + ".img.png"
    Image.new("RGB", (40, 40), (200, 30, 30)).save(png)
    prs = Presentation(path)
    pic = list(prs.slides)[slide_index].shapes.add_picture(png, Inches(6), Inches(4))
    if name:
        pic.name = name
    prs.save(path)


def shape_by_name(slide, name):
    hits = [sh for sh in slide.shapes if sh.name == name]
    expect(len(hits) == 1, f"shape {name!r} unique")
    return hits[0]


def scenario_clone(workdir, scripts):
    build = load_module(scripts, "build_deck")
    tpl = build_template(os.path.join(workdir, "tpl.pptx"))
    add_picture(tpl, slide_index=1, name="Visuel 1")
    prs = Presentation(tpl)
    expect(len(list(prs.slides)) == 3, "template has 3 slides")
    clone = build.clone_slide(prs, list(prs.slides)[1])
    expect(len(list(prs.slides)) == 4, "clone appended")
    pics = [sh for sh in clone.shapes if sh.shape_type == 13]
    expect(len(pics) == 1, "clone carries the picture")
    out = os.path.join(workdir, "cloned.pptx")
    prs.save(out)
    p2 = Presentation(out)
    pics2 = [sh for sh in list(p2.slides)[3].shapes if sh.shape_type == 13]
    expect(len(pics2) == 1, "reopened clone still carries the picture")
    expect(pics2[0].image.blob == pics[0].image.blob, "picture blob identical after reopen")


def scenario_zones(workdir, scripts):
    build = load_module(scripts, "build_deck")
    path = os.path.join(workdir, "z.pptx")
    prs = Presentation()
    s = prs.slides.add_slide(prs.slide_layouts[6])
    box = s.shapes.add_textbox(Inches(1), Inches(1), Inches(3), Inches(1.5))
    box.name = "Multi"
    tf = box.text_frame
    tf.text = "un"
    r0 = tf.paragraphs[0].runs[0]
    r0.font.size = Pt(24)
    for line in ("deux", "trois"):
        p = tf.add_paragraph()
        p.text = line
    build.set_zone(box, {"paras": ["alpha"]})
    expect(len(tf.paragraphs) == 3, "paragraph count preserved")
    expect(tf.paragraphs[0].text == "alpha", "first paragraph replaced")
    expect(tf.paragraphs[1].text == "" and tf.paragraphs[2].text == "", "extra paragraphs blanked")
    expect(tf.paragraphs[0].runs[0].font.size == Pt(24), "first-run formatting preserved")
    build.set_zone(box, {"paras": ["alpha"], "color": "051742", "size": 18})
    from pptx.dml.color import RGBColor
    expect(tf.paragraphs[0].runs[0].font.color.rgb == RGBColor.from_string("051742"),
           "explicit zone color applied")
    expect(tf.paragraphs[0].runs[0].font.size == Pt(18), "explicit zone size applied")
    prs.save(path)
    p2 = Presentation(path)
    box2 = shape_by_name(list(p2.slides)[0], "Multi")
    expect(box2.text_frame.paragraphs[0].text == "alpha", "replacement survives save/reopen")


def spec_entry(entree, zones=None, pinned=None, placeholders=None, notes=None):
    e = {"entree": entree}
    if zones is not None:
        e["zones"] = zones
    if placeholders is not None:
        e["placeholders"] = placeholders
    if pinned is not None:
        e["pinned"] = pinned
    if notes is not None:
        e["notes"] = notes
    return e


def scenario_plan(workdir, scripts):
    upd = load_module(scripts, "update_deck")
    old = [
        {"pos": 0, "entree": "motif:0", "motif": 0, "layout": "L", "zones": {"A": "x"}, "placeholders": {}, "pinned": False, "notes": None},
        {"pos": 1, "entree": "motif:1", "motif": 1, "layout": "L", "zones": {"B": "y"}, "placeholders": {}, "pinned": True, "notes": None},
        {"pos": 2, "entree": "motif:2", "motif": 2, "layout": "L", "zones": {"C": "z"}, "placeholders": {}, "pinned": False, "notes": None},
        {"pos": 3, "entree": "motif:1", "motif": 1, "layout": "L", "zones": {"B": "w"}, "placeholders": {}, "pinned": False, "notes": None},
    ]
    new = [
        spec_entry("motif:0", {"A": "x"}),            # identical -> keep
        spec_entry("motif:1", {"B": "y2"}, pinned=True),  # changed + pinned -> pin_keep
        spec_entry("motif:0", {"A": "z2"}),           # changed entree + content -> regen
    ]
    actions = upd.plan_update(old, new)
    got = [a["action"] for a in actions]
    expect(got == ["keep", "pin_keep", "regen", "delete"], f"classification wrong: {got}")
    expect(actions[3]["old_pos"] == 3, "delete keeps old index")

    actions2 = upd.plan_update(old[:2], new[:2] + [spec_entry("motif:0", {"A": "n"})])
    got2 = [a["action"] for a in actions2]
    expect(got2 == ["keep", "pin_keep", "add"], f"add classification wrong: {got2}")


def build_deck_cli(scripts, spec, workdir, name):
    spec_path = os.path.join(workdir, name + "-spec.json")
    with open(spec_path, "w", encoding="utf8") as f:
        json.dump(spec, f, ensure_ascii=False)
    r = subprocess.run([sys.executable, os.path.join(scripts, "build_deck.py"), spec_path],
                       capture_output=True, text=True)
    expect(r.returncode == 0, f"build_deck failed: {r.stdout} {r.stderr}")
    return spec["output"]


def update_deck_cli(scripts, deck, spec, workdir, name):
    spec_path = os.path.join(workdir, name + "-spec.json")
    with open(spec_path, "w", encoding="utf8") as f:
        json.dump(spec, f, ensure_ascii=False)
    r = subprocess.run([sys.executable, os.path.join(scripts, "update_deck.py"), deck, spec_path],
                       capture_output=True, text=True)
    expect(r.returncode == 0, f"update_deck failed: {r.stdout} {r.stderr}")
    return r.stdout


def slide_text(prs, pos, shape_name):
    return shape_by_name(list(prs.slides)[pos], shape_name).text_frame.text


def scenario_apply(workdir, scripts):
    tpl = build_template(os.path.join(workdir, "tpl2.pptx"))
    spec = {
        "template": tpl,
        "output": os.path.join(workdir, "deck.pptx"),
        "slides": [
            spec_entry("motif:0", {"Titre 1": "A"}),
            spec_entry("motif:1", {"Carte 1": {"paras": ["P", "pied"]}}, pinned=True),
            spec_entry("motif:2", {"Zone 1": "Z"}),
        ],
    }
    deck = build_deck_cli(scripts, spec, workdir, "base")
    prs = Presentation(deck)
    expect(len(list(prs.slides)) == 3, "deck built with 3 slides")

    new_spec = {
        "template": tpl,
        "output": os.path.join(workdir, "deck.pptx"),
        "slides": [
            spec_entry("motif:0", {"Titre 1": "A2"}),
            spec_entry("motif:1", {"Carte 1": {"paras": ["P2", "pied2"]}}, pinned=True),
            spec_entry("motif:2", {"Zone 1": "Z"}),
        ],
    }
    update_deck_cli(scripts, deck, new_spec, workdir, "upd")
    p2 = Presentation(deck)
    expect(len(list(p2.slides)) == 3, "update keeps 3 slides")
    expect(slide_text(p2, 0, "Titre 1") == "A2", "changed non-pinned slide regenerated")
    expect(slide_text(p2, 1, "Carte 1").startswith("P\n"), "pinned slide kept as-is")
    expect(slide_text(p2, 2, "Zone 1") == "Z", "identical slide untouched")
    manifest = json.load(open(deck + ".manifest.json"))
    expect([s["pinned"] for s in manifest["slides"]] == [False, True, False], "manifest pinned flags updated")
    expect([s["pos"] for s in manifest["slides"]] == [0, 1, 2], "manifest positions stable")


def scenario_adddelete(workdir, scripts):
    tpl = build_template(os.path.join(workdir, "tpl3.pptx"))
    spec = {
        "template": tpl,
        "output": os.path.join(workdir, "deck2.pptx"),
        "slides": [spec_entry("motif:0", {"Titre 1": "X"})],
    }
    deck = build_deck_cli(scripts, spec, workdir, "ad")

    add_spec = {
        "template": tpl,
        "output": os.path.join(workdir, "deck2.pptx"),
        "slides": [
            spec_entry("motif:0", {"Titre 1": "X"}),
            spec_entry("motif:0", {"Titre 1": "Y"}),
        ],
    }
    update_deck_cli(scripts, deck, add_spec, workdir, "add")
    p2 = Presentation(deck)
    expect(len(list(p2.slides)) == 2, "slide added in place")
    expect(slide_text(p2, 0, "Titre 1") == "X" and slide_text(p2, 1, "Titre 1") == "Y", "added slide ordered and filled")

    del_spec = {
        "template": tpl,
        "output": os.path.join(workdir, "deck2.pptx"),
        "slides": [spec_entry("motif:0", {"Titre 1": "X2"})],
    }
    update_deck_cli(scripts, deck, del_spec, workdir, "del")
    p3 = Presentation(deck)
    expect(len(list(p3.slides)) == 1, "slide dropped")
    expect(slide_text(p3, 0, "Titre 1") == "X2", "remaining slide regenerated")


def main():
    scenario, workdir, scripts = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(workdir, exist_ok=True)
    {"clone": scenario_clone,
     "zones": scenario_zones,
     "plan": scenario_plan,
     "apply": scenario_apply,
     "adddelete": scenario_adddelete}[scenario](workdir, scripts)
    print(f"{scenario}: ok")


if __name__ == "__main__":
    main()
