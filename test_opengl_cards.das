options gen2
options no_aot
options persistent_heap

require cards/opengl_cards
require math
require dastest/testing_boost public

// Tests for pure functions that don't need an OpenGL context

[test]
def test_is_playing_card_suits(t : T?) {
    t |> equal(is_playing_card("club_1"), true)
    t |> equal(is_playing_card("club_king"), true)
    t |> equal(is_playing_card("diamond_1"), true)
    t |> equal(is_playing_card("diamond_queen"), true)
    t |> equal(is_playing_card("heart_1"), true)
    t |> equal(is_playing_card("heart_jack"), true)
    t |> equal(is_playing_card("spade_1"), true)
    t |> equal(is_playing_card("spade_10"), true)
}

[test]
def test_is_playing_card_specials(t : T?) {
    t |> equal(is_playing_card("back"), true)
    t |> equal(is_playing_card("alternate-back"), true)
    t |> equal(is_playing_card("joker_black"), true)
    t |> equal(is_playing_card("joker_red"), true)
}

[test]
def test_is_playing_card_rejects(t : T?) {
    t |> equal(is_playing_card(""), false)
    t |> equal(is_playing_card("unknown"), false)
    t |> equal(is_playing_card("Club_1"), false)     // case sensitive
    t |> equal(is_playing_card("hearts_1"), false)    // wrong prefix
    t |> equal(is_playing_card("backside"), false)    // partial match
    t |> equal(is_playing_card("joker"), false)       // incomplete
}

[test]
def test_card_size_unit(t : T?) {
    let size = card_size(1.0)
    t |> success(abs(size.x - CARD_DOC_WIDTH) < 0.01, "scale 1.0 should match doc width")
    t |> success(abs(size.y - CARD_DOC_HEIGHT) < 0.01, "scale 1.0 should match doc height")
}

[test]
def test_card_size_scaling(t : T?) {
    let s1 = card_size(1.0)
    let s2 = card_size(2.0)
    t |> success(abs(s2.x - s1.x * 2.0) < 0.01, "2x scale should double width")
    t |> success(abs(s2.y - s1.y * 2.0) < 0.01, "2x scale should double height")
    let s05 = card_size(0.5)
    t |> success(abs(s05.x - s1.x * 0.5) < 0.01, "0.5x scale should halve width")
}

[test]
def test_card_size_zero(t : T?) {
    let size = card_size(0.0)
    t |> success(abs(size.x) < 0.01, "zero scale should give zero size")
    t |> success(abs(size.y) < 0.01, "zero scale should give zero size")
}

[test]
def test_card_doc_dimensions(t : T?) {
    // verify constants are sane
    t |> success(CARD_DOC_WIDTH > 100.0 && CARD_DOC_WIDTH < 200.0, "card width should be reasonable")
    t |> success(CARD_DOC_HEIGHT > 200.0 && CARD_DOC_HEIGHT < 300.0, "card height should be reasonable")
    t |> success(CARD_DOC_HEIGHT > CARD_DOC_WIDTH, "cards should be taller than wide")
}

[test]
def test_find_card_in_empty_deck(t : T?) {
    var deck : GpuDeck
    t |> equal(find_card(deck, "heart_1"), -1)
    t |> equal(find_card(deck, ""), -1)
    t |> equal(card_count(deck), 0)
}

[test]
def test_find_card_with_names(t : T?) {
    var deck : GpuDeck
    deck.names |> push("back")
    deck.names |> push("club_1")
    deck.names |> push("heart_queen")
    t |> equal(find_card(deck, "back"), 0)
    t |> equal(find_card(deck, "club_1"), 1)
    t |> equal(find_card(deck, "heart_queen"), 2)
    t |> equal(find_card(deck, "missing"), -1)
    t |> equal(find_card(deck, ""), -1)
}
