---
name: pptx-branded
description: "Generate or update branded PowerPoint decks from a clean extracted template. Use when the user asks for a presentation that must respect the company charte (Néosoft template), when regenerating slides from a deck-spec JSON, or when updating an existing branded deck without breaking the branding."
---

# PPTX « branded » — génération et mise à jour à charte

## Principe

Un **template propre** (extrait une fois d'un deck marqué, ex. `data/pptx-skill-design/template-extract/template-neosoft-clean.pptx`) sert de base. On ne réinvente **jamais** la géométrie : chaque slide cible est soit
- **`layout:<nom>`** — slide structurante créée depuis un vrai layout (couverture, sommaire, chapitre, fermeture) : l'agent ne remplit que les placeholders ;
- **`motif:<index>`** — slide de contenu clonée depuis une slide-motif du template : l'agent remplace les textes zone par zone.

## Workflow

1. **Lire le manifest** du template (`scripts/inventory_template.py <template.pptx> manifest.json`) : layouts + placeholders (idx), slides-motifs + noms de formes + textes actuels, media, palette du thème. C'est LA référence pour choisir les entrées et écrire les zones.
2. **Écrire `deck-spec.json`** :

```json
{
  "template": "data/pptx-skill-design/template-extract/template-neosoft-clean.pptx",
  "output": "out/deck.pptx",
  "slides": [
    {"entree": "motif:0",
     "zones": {"Espace réservé du texte 2": "Titre du deck",
               "Espace réservé du texte 4": "JJ/MM/AAAA"}},
    {"entree": "motif:3",
     "zones": {"Titre 1": "Retour d'expérience",
               "Rectangle 5": {"paras": ["Migration A", "−10 jours"]}}},
    {"entree": "motif:9"},
    {"entree": "layout:Light_blue"}
  ],
  "notes": {"0": "Note du présentateur"}
}
```

3. **Générer** : `python3 scripts/build_deck.py deck-spec.json` (clonage + remplacement par zones ; le texte de remplacement conserve le formatage du premier run de chaque paragraphe ; les paragraphes surnuméraires sont vidés, jamais supprimés, pour préserver la géométrie).
4. **Pictos** : `python3 scripts/pictos.py list <dir-pictos>` pour choisir, puis `insert <pptx> <slide#> <fichier.svg|png> <left> <top> [width]` (les SVG sont convertis en PNG via cairosvg, mis en cache). **Priorité aux pictos du template** (`template-extract/pictos/`, déjà dans la charte) ; Lucide en complément (décision capitaine).
5. **Valider** : `python3 scripts/validate.py out/deck.pptx --render-dir renders/` — réouverture python-pptx, contrôles statiques (résidus de placeholder, marqueurs interdits), rendu LibreOffice PDF (pages = slides), PNG pour inspection visuelle. **Jamais de fichier livré sans validation complète.**
6. **Inspecter visuellement** les PNG (débordements, textes trop longs) et itérer sur le deck-spec si besoin.

## Mode update (règle confirmée, Q3)

Tout slide **non marqué `pinned`** est régénéré lors d'un update ; une retouche manuelle survit en marquant la slide `"pinned": true` dans le deck-spec. `build_deck.py` écrit un **deck-manifest** (`<deck>-manifest.json`, miroir du spec + hachages SHA-1 par slide) à côté du deck généré.

`python3 scripts/update_deck.py <deck.pptx> <nouveau-spec.json>` met ensuite le deck à jour **en place**, position par position :
- entrée et hash identiques → slide intouchée ;
- zones modifiées (même entrée) → réapplication in situ (géométrie préservée) ;
- `pinned` (ancien manifest **ou** nouveau spec) → slide conservée telle quelle ;
- slides en plus en fin de spec → ajoutées (entrées `layout:` uniquement ; un `motif:` ajouté impose une reconstruction complète, le template n'étant plus dans le paquet) ;
- slides en moins → supprimées en fin de deck (sauf pinned) ;
- **entrée (`motif:N`/`layout:X`) modifiée à une position → refus fail-safe** : reconstruire avec `build_deck.py`.

## Pictos externes (Lucide, décision Q1)

Priorité aux pictos du template (`template-extract/pictos/`, déjà dans la charte). Lucide (licence ISC) en complément :
- `python3 scripts/pictos.py lucide search <mots>` — chercher un nom d'icône ;
- `python3 scripts/pictos.py lucide fetch <nom>` — télécharger dans `~/.cache/pptx-skill-pictos/lucide/` ;
- `python3 scripts/pictos.py insert <pptx> <slide#> <icon.svg> <left> <top> [width] [RRGGBB]` — insertion (conversion PNG cairosvg, cache) ; le dernier argument teinte l'icône (utile sur fond navy, les Lucide passent par `currentColor`).

## Règles dures

- Un motif s'utilise **tel quel** : si aucun motif ne convient, élargir la bibliothèque (retour au capitaine) au lieu d'improviser une géométrie.
- Longueur des textes : respecter les contraintes de zone ; un texte trop long déborde (défaut constaté en QA).
- Charte : ne jamais coder une couleur hors thème à la main ; utiliser la palette du manifest (`#051742`, `#0055FF`, `#FF5252`…).
- Police Chillax non incorporée : exiger la police installée sur le poste de rendu final, sinon prévoir l'export PDF.
- Les slides masquées de la source (`show="0"`) doivent être démassées si on les garde.
