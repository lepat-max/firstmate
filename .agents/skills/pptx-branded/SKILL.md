---
name: pptx-branded
description: "Generate or update branded PowerPoint decks from a clean template using a hybrid pipeline: placeholder filling for structural slides plus pattern-slide cloning for rich content. Load when the user asks for a presentation that must respect a company charte (e.g. the Neosoft template), when regenerating slides from a deck-spec JSON, or when updating an existing branded deck without breaking the branding."
---

# PPTX branded - generation and update under a charte

## Principle

A clean template (extracted once from a branded deck) is the single source of
graphic truth.
The agent never invents geometry.
Each target slide is either:

- `layout:<name>` - a structural slide created from a real layout (cover,
  table of contents, chapter, closing): the agent only fills placeholders.
- `motif:<index>` - a content slide cloned from a template pattern slide: the
  agent replaces texts zone by zone.

Template data (the .pptx, its picto library, its manifest, its renders) lives
home-side, never in this repository.
Current known instance: `data/pptx-skill-design/template-extract/`
(`template-neosoft-clean.pptx`, 11 slides, 31 SVG pictos in `pictos/`,
theme `BidTeam_2024`, fonts Chillax Semibold / Chillax).
New templates go under `data/pptx-templates/<name>/` with their manifest.

## Workflow

1. Read the template manifest if it exists, or generate it:
   `python3 scripts/inventory_template.py <template.pptx> manifest.json`.
   It lists layouts with placeholder idx, pattern slides with shape names and
   current texts, media, and the theme palette.
   This is the reference for choosing entries and writing zones.
2. Write a `deck-spec.json`:

```json
{
  "template": "<path to template.pptx>",
  "output": "out/deck.pptx",
  "slides": [
    {"entree": "motif:0",
     "zones": {"Espace réservé du texte 2": "Deck title",
               "Espace réservé du texte 4": "JJ/MM/AAAA"}},
    {"entree": "motif:3",
     "zones": {"Titre 1": "New title",
               "Rectangle 5": {"paras": ["Label", "Value"]}}},
    {"entree": "motif:9"},
    {"entree": "layout:Light_blue"}
  ],
  "notes": {"0": "Speaker note"}
}
```

   A slide may carry `"pinned": true`: it will be left untouched by updates.
3. Build: `python3 scripts/build_deck.py deck-spec.json`.
   Cloning keeps the source layout so text inherits its formatting.
   Text replacement preserves the first-run formatting of each paragraph;
   extra source paragraphs are blanked, never deleted, so geometry survives.
   A zone may carry an optional `"color": "RRGGBB"` to force the written
   first-run color - needed when a source zone inherits an unreadable color
   (seen: white-on-light in the gains motif's left card) - or an optional
   `"size": <pt>` to force the written first-run font size (seen: long cover
   titles overflow at the source's display size).
   The build writes `<output>.manifest.json`, the record consumed by updates.
4. Pictos: `python3 scripts/pictos.py list <dir-pictos>` to choose one, then
   `python3 scripts/pictos.py insert <pptx> <slide#> <file.svg|lucide:name> <left> <top> [width] [--color RRGGBB]`.
   Prefer template pictos (`pictos/` next to the template, already on-charte).
   Use Lucide (`lucide:<name>`, ISC license, cached download) only as fallback,
   recolored to the palette.
5. Validate: `python3 scripts/validate.py out/deck.pptx --render-dir renders/`.
   Reopening with python-pptx, static checks (leftover placeholder prompts,
   forbidden markers), headless LibreOffice PDF render with page count equal to
   slide count, PNG per page for visual inspection.
   Never deliver a file without full validation.
6. Inspect the rendered PNGs visually (text overflow, truncated words) and
   iterate on the deck-spec if needed.

## Update mode (captain decision Q3 confirmed)

Every slide not marked `pinned` is regenerated on update; manual edits survive
only by marking the slide `pinned`.
Run `python3 scripts/update_deck.py <deck.pptx> <new-deck-spec.json>` against
the existing deck and its `<deck>.manifest.json`.
Unchanged slides are left untouched; changed non-pinned slides are re-cloned in
place and re-filled; added slides are cloned from another deck slide with the
same motif; removed slides are dropped.
If an update needs a motif the deck does not contain yet and any slide is
pinned, the update aborts - rebuild the whole deck instead (a cross-package
clone could corrupt it).

## Hard rules

- A motif is used as-is: if no motif fits, widen the pattern library (back to
  the captain) instead of improvising geometry.
- Respect zone length constraints; a too-long text overflows (seen in QA).
- Never hand-code a color outside the theme palette; use the manifest palette.
- Font Chillax is not embedded: require it installed on the final rendering
  machine, or plan a PDF export.
- Unmask hidden source slides (`show="0"`) if they are kept.

## Tests

`tests/pptx-branded.test.sh` in the repository exercises cloning, zone
replacement, and the update diff on synthetic decks; it needs a Python with
`python-pptx` (set `PPTX_SKILL_PYTHON`, or it skips when unavailable).
