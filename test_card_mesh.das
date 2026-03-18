options gen2
options no_aot
options persistent_heap

require cards/card_mesh
require math
require fio
require dastest/testing_boost public

[test]
def test_parse_hex_color(t : T?) {
    let red = parse_hex_color("#e6180a")
    t |> success(red.x > 0.89 && red.x < 0.91)  // 0xe6/0xff ≈ 0.902
    t |> success(red.y > 0.09 && red.y < 0.10)   // 0x18/0xff ≈ 0.094
    t |> success(red.w > 0.99)                    // alpha = 1.0
    let none_color = parse_hex_color("none")
    t |> success(none_color.w < 0.01)             // alpha = 0.0
}

[test]
def test_extract_fill_from_style(t : T?) {
    let fill = extract_fill_from_style("fill:#FFFFFF;stroke:#000000;stroke-width:2.5")
    t |> success(fill.x > 0.99 && fill.y > 0.99 && fill.z > 0.99)
}

[test]
def test_parse_transform_translate(t : T?) {
    let xf = parse_transform("translate(-166.325,-249.75499)")
    t |> success(xf.e < -166.0 && xf.e > -167.0)
    t |> success(xf.f < -249.0 && xf.f > -250.0)
    t |> success(xf.a > 0.99 && xf.d > 0.99) // identity scale
}

[test]
def test_parse_transform_scale(t : T?) {
    let xf = parse_transform("scale(2.4,2.4)")
    t |> success(xf.a > 2.39 && xf.a < 2.41)
    t |> success(xf.d > 2.39 && xf.d < 2.41)
}

[test]
def test_parse_transform_matrix(t : T?) {
    let xf = parse_transform("matrix(-2.4,0,0,-2.4,83.2875,117.635)")
    t |> success(xf.a < -2.39 && xf.a > -2.41)
    t |> success(xf.e > 83.0 && xf.e < 84.0)
}

[test]
def test_load_deck(t : T?) {
    // requires CWD to be the dasCards directory
    let f = fopen("cards/svg-cards.svg", "rb")
    if (f == null) {
        return  // skip when run from wrong CWD
    }
    fclose(f)
    let deck = load_deck("cards/svg-cards.svg")
    t |> success(length(deck.components) > 10, "should load components")
    t |> success(length(deck.cards) > 40, "should load cards")
}

[test]
def test_parse_hex_color_lowercase(t : T?) {
    let c = parse_hex_color("#aabbcc")
    t |> success(abs(c.x - 0.667) < 0.01)   // 0xaa/0xff
    t |> success(abs(c.y - 0.733) < 0.01)   // 0xbb/0xff
    t |> success(abs(c.z - 0.8) < 0.01)     // 0xcc/0xff
    t |> success(c.w > 0.99)
}

[test]
def test_parse_hex_color_white(t : T?) {
    let c = parse_hex_color("#FFFFFF")
    t |> success(c.x > 0.99 && c.y > 0.99 && c.z > 0.99)
    t |> success(c.w > 0.99)
}

[test]
def test_parse_hex_color_black(t : T?) {
    let c = parse_hex_color("#000000")
    t |> success(c.x < 0.01 && c.y < 0.01 && c.z < 0.01)
    t |> success(c.w > 0.99)
}

[test]
def test_parse_hex_color_empty(t : T?) {
    // empty string is not "none" — returns opaque black (fallback)
    let c = parse_hex_color("")
    t |> success(c.w > 0.99, "empty string returns opaque black")
}

[test]
def test_parse_hex_color_none(t : T?) {
    let c = parse_hex_color("none")
    t |> success(c.w < 0.01, "none should return transparent")
}

[test]
def test_extract_fill_none(t : T?) {
    let fill = extract_fill_from_style("fill:none;stroke:#000000")
    t |> success(fill.w < 0.01, "fill:none should be transparent")
}

[test]
def test_extract_fill_no_fill(t : T?) {
    // no fill: key → returns opaque black (fallback)
    let fill = extract_fill_from_style("stroke:#FF0000;stroke-width:2")
    t |> success(fill.w > 0.99, "no fill in style returns opaque black")
}

[test]
def test_parse_transform_identity(t : T?) {
    let xf = parse_transform("")
    t |> success(abs(xf.a - 1.0) < 0.01)
    t |> success(abs(xf.d - 1.0) < 0.01)
    t |> success(abs(xf.e) < 0.01)
    t |> success(abs(xf.f) < 0.01)
}

[test]
def test_parse_transform_negative(t : T?) {
    let xf = parse_transform("translate(-100.5, -200.75)")
    t |> success(abs(xf.e - (-100.5)) < 0.01)
    t |> success(abs(xf.f - (-200.75)) < 0.01)
}

[test]
def test_parse_transform_scale_uniform(t : T?) {
    let xf = parse_transform("scale(0.5)")
    t |> success(abs(xf.a - 0.5) < 0.01)
    // uniform scale: d should also be 0.5
    t |> success(abs(xf.d - 0.5) < 0.01)
}
