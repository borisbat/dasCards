options gen2
options persistent_heap

require glfw/glfw_boost
require live/glfw_live
require opengl/opengl_boost
require opengl/opengl_cache
require live/opengl_live
require live/live_commands
require live/live_api
require live/live_watch_boost
require live/live_vars
require daslib/json
require daslib/json_boost
require live_host
require strings

require cards/opengl_cards

// ============================================================================
// State
// ============================================================================

var renderer : CardRenderer
var gpu_deck : GpuDeck
var display_w = 0
var display_h = 0

var @live scroll_y = 0.0
var @live card_scale = 0.55
var @live bg_color = float3(0.08, 0.12, 0.08)
var @live focus_card = -1

let CARD_PADDING = 6.0
let CARDS_PER_ROW = 13

// ============================================================================
// Live commands
// ============================================================================

struct CmdScaleArgs {
    scale : float = 0.55
}

struct CmdFocusArgs {
    card : string = ""
}

[live_command(description="Set card scale. Args: scale (float)")]
def cmd_set_scale(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdScaleArgs>)
    card_scale = args.scale
    return JV("scale={card_scale}")
}

[live_command(description="List loaded card names")]
def cmd_list_cards(input : JsonValue?) : JsonValue? {
    return JV(gpu_deck.names)
}

[live_command(description="Focus on a single card by name. Empty to show all.")]
def cmd_focus(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdFocusArgs>)
    if (length(args.card) == 0) {
        focus_card = -1
        return JV("showing all cards")
    }
    let idx = find_card(gpu_deck, args.card)
    if (idx >= 0) {
        focus_card = idx
        return JV("focused on {args.card} (index {idx})")
    }
    return JV("card not found: {args.card}")
}

// ============================================================================
// Lifecycle
// ============================================================================

[export]
def init() {
    live_create_window("Card Viewer", 1280, 800)
    renderer = create_card_renderer()
    gpu_deck <- load_gpu_deck("cards/svg-cards.svg")
    print("card viewer: init (is_reload={is_reload()}, cards={card_count(gpu_deck)})\n")
}

[export]
def update() {
    if (!live_begin_frame()) {
        return
    }
    live_get_framebuffer_size(display_w, display_h)
    glViewport(0, 0, display_w, display_h)
    glClearColor(bg_color.x, bg_color.y, bg_color.z, 1.0)
    glClear(GL_COLOR_BUFFER_BIT)
    glDisable(GL_DEPTH_TEST)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    // Scroll with arrow keys
    let dt = get_dt()
    if (glfwGetKey(live_window, int(GLFW_KEY_DOWN)) == int(GLFW_PRESS)) {
        scroll_y += 400.0 * dt
    }
    if (glfwGetKey(live_window, int(GLFW_KEY_UP)) == int(GLFW_PRESS)) {
        scroll_y -= 400.0 * dt
    }
    if (glfwGetKey(live_window, int(GLFW_KEY_PAGE_DOWN)) == int(GLFW_PRESS)) {
        scroll_y += 1200.0 * dt
    }
    if (glfwGetKey(live_window, int(GLFW_KEY_PAGE_UP)) == int(GLFW_PRESS)) {
        scroll_y -= 1200.0 * dt
    }
    if (scroll_y < 0.0) {
        scroll_y = 0.0
    }

    // Scale with +/-
    if (glfwGetKey(live_window, int(GLFW_KEY_EQUAL)) == int(GLFW_PRESS)) {
        card_scale += 2.0 * dt
    }
    if (glfwGetKey(live_window, int(GLFW_KEY_MINUS)) == int(GLFW_PRESS)) {
        card_scale -= 2.0 * dt
        if (card_scale < 0.5) {
            card_scale = 0.5
        }
    }

    // Lay out cards in a grid
    let cs = card_size(card_scale)
    let grid_w = cs.x + CARD_PADDING
    let grid_h = cs.y + CARD_PADDING
    let start_x = CARD_PADDING
    let start_y = CARD_PADDING - scroll_y
    let num_cards = card_count(gpu_deck)

    if (focus_card >= 0 && focus_card < num_cards) {
        let cx = (float(display_w) - cs.x) * 0.5
        let cy = (float(display_h) - cs.y) * 0.5
        draw_card(renderer, gpu_deck, focus_card, cx, cy, card_scale, display_w, display_h)
    } else {
        for (i in range(num_cards)) {
            let col = i % CARDS_PER_ROW
            let row = i / CARDS_PER_ROW
            let x = start_x + float(col) * grid_w
            let y = start_y + float(row) * grid_h
            if (y + cs.y < 0.0 || y > float(display_h)) {
                continue
            }
            draw_card(renderer, gpu_deck, i, x, y, card_scale, display_w, display_h)
        }
    }

    glDisable(GL_BLEND)
    live_end_frame()
}

[export]
def shutdown() {
    print("card viewer: shutdown\n")
    live_destroy_window()
}

[export]
def main() {
    init()
    while (!exit_requested()) {
        update()
    }
    shutdown()
}
