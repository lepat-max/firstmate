"""Tests for pptx-branded core logic: slide cloning, zone replacement,
diff-based update, and manifest emission.

Run with the task venv:  pytest .agents/skills/pptx-branded/tests/
Only python-pptx's stock template is used — no branded template dependency.
"""
import json
import os
import sys

import pytest
from pptx import Presentation
from pptx.util import Inches, Pt

SCRIPTS = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, SCRIPTS)

from build_deck import clone_slide, find_layout, resolve_shape, set_zone  # noqa: E402
from update_deck import delete_slide, entry_hash, reapply  # noqa: E402


@pytest.fixture
def prs(tmp_path):
    p = Presentation()
    return p


def add_textbox(slide, name, lines):
    box = slide.shapes.add_textbox(Inches(1), Inches(1), Inches(3), Inches(1))
    box.name = name
    tf = box.text_frame
    tf.text = lines[0]
    for line in lines[1:]:
        p = tf.add_paragraph()
        p.text = line
    return box


def test_clone_slide_keeps_layout(prs):
    src = prs.slides.add_slide(prs.slide_layouts[1])
    box = add_textbox(src, "Zone A", ["ligne 1", "ligne 2"])
    new = clone_slide(prs, src)
    assert new.slide_layout is src.slide_layout
    names = [sh.name for sh in new.shapes]
    assert "Zone A" in names
    # deepcopied shapes are distinct elements
    assert list(new.shapes)[0]._element is not box._element


def test_set_zone_preserves_paragraph_count(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    box = add_textbox(slide, "Zone A", ["un", "deux", "trois"])
    set_zone(box, {"paras": ["alpha"]})
    tf = box.text_frame
    assert len(tf.paragraphs) == 3
    assert tf.paragraphs[0].text == "alpha"
    assert tf.paragraphs[1].text == ""
    assert tf.paragraphs[2].text == ""


def test_resolve_shape_by_name_and_match(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    add_textbox(slide, "Carte", ["GAUCHE: texte"])
    add_textbox(slide, "Carte", ["DROITE: texte"])
    both = [sh for sh in slide.shapes if sh.name == "Carte"]
    assert len(both) == 2
    left = resolve_shape(slide, "Carte", match="GAUCHE")
    right = resolve_shape(slide, "Carte", match="DROITE")
    assert left is not right
    assert left.text_frame.text.startswith("GAUCHE")


def test_find_layout_unknown_raises(prs):
    with pytest.raises(SystemExit):
        find_layout(prs, "layout qui n'existe pas")


def test_entry_hash_ignores_pinned():
    a = {"entree": "motif:1", "zones": {"X": "a"}}
    b = {"entree": "motif:1", "zones": {"X": "a"}, "pinned": True}
    assert entry_hash(a) == entry_hash(b)
    c = {"entree": "motif:1", "zones": {"X": "b"}}
    assert entry_hash(a) != entry_hash(c)


def test_reapply_updates_zones_in_place(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    add_textbox(slide, "Titre", ["ancien"])
    reapply(slide, {"entree": "motif:0", "zones": {"Titre": "nouveau"}})
    assert slide.shapes[0].text_frame.text == "nouveau"


def test_delete_slide_removes_last(prs):
    prs.slides.add_slide(prs.slide_layouts[6])
    prs.slides.add_slide(prs.slide_layouts[6])
    assert len(list(prs.slides)) == 2
    delete_slide(prs, 1)
    assert len(list(prs.slides)) == 1


def test_build_deck_emits_manifest(tmp_path):
    from build_deck import main as build_main

    tpl_path = str(tmp_path / "tpl.pptx")
    out_path = str(tmp_path / "out.pptx")
    tpl = Presentation()
    s = tpl.slides.add_slide(tpl.slide_layouts[6])
    add_textbox(s, "Titre", ["template"])
    tpl.save(tpl_path)

    spec = {
        "template": tpl_path,
        "output": out_path,
        "slides": [
            {"entree": "motif:0", "zones": {"Titre": "genere"}},
            {"entree": "layout:Blank", "pinned": True},
        ],
    }
    spec_path = str(tmp_path / "spec.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f)
    build_main(spec_path)

    deck = Presentation(out_path)
    assert len(list(deck.slides)) == 2
    assert deck.slides[0].shapes[0].text_frame.text == "genere"

    manifest_path = str(tmp_path / "out-manifest.json")
    assert os.path.exists(manifest_path)
    manifest = json.load(open(manifest_path))
    assert [e["entree"] for e in manifest["slides"]] == ["motif:0", "layout:Blank"]
    assert manifest["slides"][1]["pinned"] is True
    assert all(len(e["hash"]) == 40 for e in manifest["slides"])


def test_update_refuses_changed_entree(tmp_path, capsys):
    from update_deck import main as update_main

    tpl_path = str(tmp_path / "tpl.pptx")
    tpl = Presentation()
    tpl.slides.add_slide(tpl.slide_layouts[6])
    tpl.save(tpl_path)

    def spec_with(entries, name):
        path = str(tmp_path / name)
        with open(path, "w") as f:
            json.dump({"template": tpl_path, "output": str(tmp_path / "out.pptx"),
                       "slides": entries}, f)
        return path

    build_spec = spec_with([{"entree": "motif:0"}], "s1.json")
    from build_deck import main as build_main
    build_main(build_spec)

    other_spec = spec_with([{"entree": "layout:Blank"}], "s2.json")
    with pytest.raises(SystemExit):
        update_main(str(tmp_path / "out.pptx"), other_spec)


def test_update_skips_identical_and_reapplies_changed(tmp_path):
    from build_deck import main as build_main
    from update_deck import main as update_main

    tpl_path = str(tmp_path / "tpl.pptx")
    tpl = Presentation()
    s = tpl.slides.add_slide(tpl.slide_layouts[6])
    add_textbox(s, "Titre", ["original"])
    add_textbox(s, "Kpi", ["100"])
    tpl.save(tpl_path)

    spec = {"template": tpl_path, "output": str(tmp_path / "out.pptx"),
            "slides": [{"entree": "motif:0",
                        "zones": {"Titre": "v1", "Kpi": "100"}}]}
    spec_path = str(tmp_path / "s1.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f)
    build_main(spec_path)

    # identical spec -> no slide touched (content stays, manifest refreshed)
    spec2 = dict(spec)
    spec2["slides"] = [dict(spec["slides"][0])]
    spec2_path = str(tmp_path / "s2.json")
    with open(spec2_path, "w") as f:
        json.dump(spec2, f)
    update_main(str(tmp_path / "out.pptx"), spec2_path)
    deck = Presentation(str(tmp_path / "out.pptx"))
    assert deck.slides[0].shapes[0].text_frame.text == "v1"

    # changed zone -> reapplied in place
    spec3 = dict(spec)
    spec3["slides"] = [{"entree": "motif:0",
                        "zones": {"Titre": "v2", "Kpi": "250"}}]
    spec3_path = str(tmp_path / "s3.json")
    with open(spec3_path, "w") as f:
        json.dump(spec3, f)
    update_main(str(tmp_path / "out.pptx"), spec3_path)
    deck = Presentation(str(tmp_path / "out.pptx"))
    texts = {sh.name: sh.text_frame.text for sh in deck.slides[0].shapes}
    assert texts["Titre"] == "v2"
    assert texts["Kpi"] == "250"


def test_update_pinned_slide_survives(tmp_path):
    from build_deck import main as build_main
    from update_deck import main as update_main

    tpl_path = str(tmp_path / "tpl.pptx")
    tpl = Presentation()
    s = tpl.slides.add_slide(tpl.slide_layouts[6])
    add_textbox(s, "Titre", ["original"])
    tpl.save(tpl_path)

    spec = {"template": tpl_path, "output": str(tmp_path / "out.pptx"),
            "slides": [{"entree": "motif:0", "zones": {"Titre": "v1"}}]}
    spec_path = str(tmp_path / "s1.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f)
    build_main(spec_path)

    # manual retouch simulated on the deck, then pinned in the new spec
    deck = Presentation(str(tmp_path / "out.pptx"))
    deck.slides[0].shapes[0].text_frame.text = "RETOUCHE MANUELLE"
    deck.save(str(tmp_path / "out.pptx"))

    spec2 = {"template": tpl_path, "output": str(tmp_path / "out.pptx"),
             "slides": [{"entree": "motif:0", "zones": {"Titre": "v2"},
                         "pinned": True}]}
    spec2_path = str(tmp_path / "s2.json")
    with open(spec2_path, "w") as f:
        json.dump(spec2, f)
    update_main(str(tmp_path / "out.pptx"), spec2_path)
    deck = Presentation(str(tmp_path / "out.pptx"))
    assert deck.slides[0].shapes[0].text_frame.text == "RETOUCHE MANUELLE"


def test_update_appends_layout_and_deletes_trailing(tmp_path):
    from build_deck import main as build_main
    from update_deck import main as update_main

    tpl_path = str(tmp_path / "tpl.pptx")
    tpl = Presentation()
    tpl.slides.add_slide(tpl.slide_layouts[6])
    tpl.save(tpl_path)

    def write_spec(entries, name):
        path = str(tmp_path / name)
        with open(path, "w") as f:
            json.dump({"template": tpl_path, "output": str(tmp_path / "out.pptx"),
                       "slides": entries}, f)
        return path

    build_main(write_spec([{"entree": "motif:0"}], "s1.json"))
    assert len(list(Presentation(str(tmp_path / "out.pptx")).slides)) == 1

    update_main(str(tmp_path / "out.pptx"),
                write_spec([{"entree": "motif:0"}, {"entree": "layout:Blank"}], "s2.json"))
    assert len(list(Presentation(str(tmp_path / "out.pptx")).slides)) == 2

    update_main(str(tmp_path / "out.pptx"),
                write_spec([{"entree": "motif:0"}], "s3.json"))
    assert len(list(Presentation(str(tmp_path / "out.pptx")).slides)) == 1
