options gen2
options no_aot
options persistent_heap

require cards/card_mesh
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
    let deck = load_deck("cards/svg-cards.svg")
    t |> success(length(deck.components) > 10)
    t |> success(length(deck.cards) > 40)
    print("  components: {length(deck.components)}, cards: {length(deck.cards)}\n")
}
