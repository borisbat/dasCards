options gen2
options no_aot
options persistent_heap

require cards/glyph_path
require cards/svg_path
require math
require fio
require dastest/testing_boost public

let FONT_PATH = "cards/DejaVuSerif.ttf"

def font_available() : bool {
    let f = fopen(FONT_PATH, "rb")
    if (f != null) {
        fclose(f)
        return true
    }
    return false
}

// ============================================================================
// Tests that don't need the font file
// ============================================================================

[test]
def test_load_font_missing_file(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    t |> equal(font.loaded, false)
}

[test]
def test_get_font_scale_unloaded(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    let scale = get_font_scale(font, 24.0)
    t |> success(abs(scale - 1.0) < 0.01, "unloaded font returns 1.0")
}

[test]
def test_get_font_ascent_unloaded(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    let ascent = get_font_ascent(font, 1.0)
    t |> success(abs(ascent) < 0.01, "unloaded font returns 0.0")
}

[test]
def test_get_codepoint_advance_unloaded(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    let adv = get_codepoint_advance(font, int('A'), 1.0)
    t |> success(abs(adv) < 0.01, "unloaded font returns 0.0")
}

[test]
def test_get_glyph_path_unloaded(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    let path = get_glyph_path(font, int('A'), 1.0)
    t |> equal(length(path.contours), 0)
}

[test]
def test_measure_text_width_unloaded(t : T?) {
    let font = load_glyph_font("nonexistent.ttf")
    let w = measure_text_width(font, "Hello", 22.0)
    t |> success(abs(w) < 0.01, "unloaded font returns 0.0")
}

// ============================================================================
// Tests that require the font file (skipped if not found)
// ============================================================================

[test]
def test_load_font_success(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    t |> equal(font.loaded, true)
}

[test]
def test_get_font_scale(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let scale = get_font_scale(font, 24.0)
    t |> success(scale > 0.001 && scale < 1.0, "scale should be a small fraction")
    let scale2 = get_font_scale(font, 48.0)
    t |> success(scale2 > scale, "double pixel height should increase scale")
}

[test]
def test_get_font_ascent(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let scale = get_font_scale(font, 24.0)
    let ascent = get_font_ascent(font, scale)
    t |> success(ascent > 0.0, "ascent should be positive")
}

[test]
def test_get_codepoint_advance(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let scale = get_font_scale(font, 24.0)
    let adv_A = get_codepoint_advance(font, int('A'), scale)
    let adv_i = get_codepoint_advance(font, int('i'), scale)
    t |> success(adv_A > 0.0, "A advance should be positive")
    t |> success(adv_i > 0.0, "i advance should be positive")
    t |> success(adv_A > adv_i, "A should be wider than i")
}

[test]
def test_get_glyph_path_letter(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let path = get_glyph_path(font, int('A'), 1.0)
    t |> success(length(path.contours) > 0, "A should have contours")
    t |> success(length(path.contours) >= 2, "A should have at least 2 contours")
}

[test]
def test_get_glyph_path_digit(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let path = get_glyph_path(font, int('8'), 1.0)
    t |> success(length(path.contours) > 0, "8 should have contours")
}

[test]
def test_get_glyph_path_space(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let path = get_glyph_path(font, int(' '), 1.0)
    t |> equal(length(path.contours), 0)
}

[test]
def test_get_glyph_path_null_codepoint(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let path = get_glyph_path(font, 0, 1.0)
    t |> success(true, "null codepoint should not crash")
}

[test]
def test_get_glyph_path_scale(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let path1 = get_glyph_path(font, int('H'), 1.0)
    let path2 = get_glyph_path(font, int('H'), 2.0)
    t |> success(length(path1.contours) > 0)
    t |> success(length(path2.contours) > 0)
    let p1 = path1.contours[0].points[0]
    let p2 = path2.contours[0].points[0]
    t |> success(abs(p2.x - p1.x * 2.0) < 0.01, "2x scale should double coordinates")
    t |> success(abs(p2.y - p1.y * 2.0) < 0.01, "2x scale should double coordinates")
}

[test]
def test_measure_text_width(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let w = measure_text_width(font, "Hello", 22.0)
    t |> success(w > 0.0, "text width should be positive")
    let w2 = measure_text_width(font, "Hello World", 22.0)
    t |> success(w2 > w, "longer text should be wider")
}

[test]
def test_measure_text_width_empty(t : T?) {
    if (!font_available()) {
        return
    }
    let font = load_glyph_font(FONT_PATH)
    let w = measure_text_width(font, "", 22.0)
    t |> success(abs(w) < 0.01, "empty string should have zero width")
}
