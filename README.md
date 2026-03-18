# das-cards

Vector playing card rendering for daslang + OpenGL. All 52 standard cards, 2 jokers, and 2 card backs rendered as sharp triangle meshes from SVG source — no textures, no rasterization, crisp at any scale.

Based on [SVG-cards](https://github.com/htdebeer/SVG-cards) v4.0.0 (LGPL-2.1).

## Install

```
daspkg install github.com/borisbat/dasCards
```

Or clone into your project's `modules/` directory.

## Quick Start

```das
options gen2

require cards/opengl_cards

var renderer : CardRenderer
var gpu_deck : GpuDeck

// During init (OpenGL context must be active):
renderer = create_card_renderer()
gpu_deck <- load_gpu_deck("cards/svg-cards.svg")

// During draw:
let idx = find_card(gpu_deck, "heart_queen")
draw_card(renderer, gpu_deck, idx, x, y, scale, screen_w, screen_h)
```

## API Reference

### Types

| Type | Description |
|------|-------------|
| `CardRenderer` | Holds the compiled shader program |
| `GpuDeck` | All uploaded card meshes + name index. Fields: `cards`, `names` |

### Functions

#### `create_card_renderer() : CardRenderer`

Create the shader program. Call once during init with an active OpenGL context.

#### `load_gpu_deck(svg_file : string) : GpuDeck`

Parse SVG, tessellate all cards, upload to GPU. Returns a deck with 56 cards sorted alphabetically by name.

#### `draw_card(renderer, deck, index, x, y, scale, screen_w, screen_h)`

Draw a single card. Position `(x, y)` is the top-left corner in screen pixels. `scale` controls card size (0.5 = half size, 1.0 = full SVG size ~167x242 pixels).

Requires `GL_BLEND` enabled with `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA` and a stencil buffer.

#### `find_card(deck, name) : int`

Find card index by name. Returns -1 if not found.

#### `card_count(deck) : int`

Number of cards in the deck (56).

#### `card_size(scale) : float2`

Card dimensions in pixels at the given scale.

#### `is_playing_card(name) : bool`

True if the name is a standard playing card, joker, or card back.

### Card Names

Names follow the pattern `{suit}_{rank}`:

- **Suits:** `club`, `diamond`, `heart`, `spade`
- **Ranks:** `1` (ace), `2`–`10`, `jack`, `queen`, `king`

Examples: `heart_1`, `spade_king`, `diamond_10`, `club_jack`

**Special cards:** `back`, `alternate-back`, `joker_black`, `joker_red`

All 56 names sorted alphabetically:

```
alternate-back    club_7           diamond_4        heart_1          heart_king       spade_4
back              club_8           diamond_5        heart_10         heart_queen      spade_5
club_1            club_9           diamond_6        heart_2          joker_black      spade_6
club_10           club_jack        diamond_7        heart_3          joker_red        spade_7
club_2            club_king        diamond_8        heart_4          spade_1          spade_8
club_3            club_queen       diamond_9        heart_5          spade_10         spade_9
club_4            diamond_1        diamond_10       heart_6          spade_2          spade_jack
club_5            diamond_2        diamond_jack     heart_7          spade_3          spade_king
club_6            diamond_3        diamond_king     heart_8                           spade_queen
                                   diamond_queen    heart_9
                                                    heart_jack
```

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `CARD_DOC_WIDTH` | 166.575 | Card width in SVG units |
| `CARD_DOC_HEIGHT` | 242.14 | Card height in SVG units |
| `CARD_DOC_MIN` | (1.25, 1.25) | SVG document origin offset |
| `CARD_DOC_MAX` | (167.825, 243.39) | SVG document extent |

## Modules

| Module | Description |
|--------|-------------|
| `cards/opengl_cards` | Public API — renderer, deck loading, drawing |
| `cards/card_mesh` | SVG parsing + tessellation → triangle meshes |
| `cards/svg_path` | SVG path `d` attribute parser + bezier flattener |
| `cards/earcut` | Polygon triangulation (mapbox/earcut port) |
| `cards/glyph_path` | Font glyph outlines via stb_truetype |

## Requirements

- daslang with OpenGL, PUGIXML, and stb_truetype modules enabled
- OpenGL context with stencil buffer support
- `cards/svg-cards.svg` — included in the package
- `cards/DejaVuSerif.ttf` — included in the package (SIL Open Font License)

## License

LGPL-2.1 (matching SVG-cards source asset).
