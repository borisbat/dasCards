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
require math
require strings
require daslib/strings_boost
require daslib/safe_addr
require daslib/math_boost
require fio

require cards/opengl_cards

// ============================================================================
// State
// ============================================================================

var renderer : CardRenderer
var gpu_deck = GpuDeck()
var display_w = 0
var display_h = 0

// Layout table: 5 rows of card indices
var rows : array<array<int>>

// Zoom animation
var zoom_card = -1           // card being animated (kept until animation ends)
var zoom_row = -1
var zoom_col = -1
var zoom_target = 0.0        // 0 = grid, 1 = zoomed in
var zoom_t = 0.0             // current interpolated value
var @live zoom_speed = 5.0
var @live bg_color = float3(0.08, 0.12, 0.08)

// 3D rotation
var rotating = false
var @live rotate_angle = 0.0
var @live rotate_speed = 0.8
var @live rotate_tilt = 0.12          // slight X-axis tilt (radians)
var back_card_idx = -1                // index of "back" card for reverse face

// Solo debug mode — draws only the focused card, no grid
var solo_mode = false
var solo_card_idx = -1
var @live solo_zoom = 0.85
var @live solo_offset = float2(0.0, 0.0)

// Mouse state
var mouse_was_pressed = false
var rmouse_was_pressed = false
var last_click_x = 0.0
var last_click_y = 0.0

// ============================================================================
// Layout helpers
// ============================================================================

let RANKS = "1;2;3;4;5;6;7;8;9;10;jack;queen;king"

def build_suit_row(suit : string) : array<int> {
    var row : array<int>
    let rank_list = split(RANKS, ";")
    for (rank in rank_list) {
        row |> push(find_card(gpu_deck, "{suit}_{rank}"))
    }
    return <- row
}

def build_layout() {
    rows |> clear()
    rows |> emplace(build_suit_row("club"))
    rows |> emplace(build_suit_row("diamond"))
    rows |> emplace(build_suit_row("heart"))
    rows |> emplace(build_suit_row("spade"))
    var specials : array<int>
    specials |> push(find_card(gpu_deck, "back"))
    specials |> push(find_card(gpu_deck, "alternate-back"))
    specials |> push(find_card(gpu_deck, "joker_black"))
    specials |> push(find_card(gpu_deck, "joker_red"))
    rows |> emplace(specials)
}

struct CardLayout {
    scale : float
    pad : float
    card_w : float
    card_h : float
    grid_w : float
    grid_h : float
    margin_x : float
    margin_y : float
}

def compute_layout() : CardLayout {
    let w = float(display_w)
    let h = float(display_h)
    let pad = 6.0
    let num_cols = 13.0
    let num_rows = 5.0
    // fit 13 cards + padding in width, 5 rows + padding in height
    let scale_x = (w - pad * (num_cols + 1.0)) / (num_cols * CARD_DOC_WIDTH)
    let scale_y = (h - pad * (num_rows + 1.0)) / (num_rows * CARD_DOC_HEIGHT)
    let scale = min(scale_x, scale_y)
    let cs = card_size(scale)
    let grid_w = cs.x + pad
    let grid_h = cs.y + pad
    let total_w = num_cols * grid_w + pad
    let total_h = num_rows * grid_h + pad
    return CardLayout(
        scale = scale,
        pad = pad,
        card_w = cs.x,
        card_h = cs.y,
        grid_w = grid_w,
        grid_h = grid_h,
        margin_x = (w - total_w) * 0.5 + pad,
        margin_y = (h - total_h) * 0.5 + pad
    )
}

def card_grid_pos(lay : CardLayout; row, col : int; num_in_row : int) : float2 {
    var x = lay.margin_x + float(col) * lay.grid_w
    // center rows with fewer than 13 cards
    if (num_in_row < 13) {
        let offset = float(13 - num_in_row) * lay.grid_w * 0.5
        x += offset
    }
    let y = lay.margin_y + float(row) * lay.grid_h
    return float2(x, y)
}

// ============================================================================
// Live commands
// ============================================================================

struct CardStatsResult {
    total_cards : int
    total_draw_ops : int
    total_stencil_groups : int
    non_stencil_batches : int
    avg_draw_calls_per_card : float
    last_frame_draws : int
    last_frame_draw_calls : int
    last_frame_triangles : int
}

[live_command(description="Card draw op breakdown")]
def cmd_card_stats(input : JsonValue?) : JsonValue? {
    var stats = CardStatsResult()
    stats.total_cards = card_count(gpu_deck)
    for (i in range(card_count(gpu_deck))) {
        let gpu & = unsafe(gpu_deck.cards[i])
        stats.total_draw_ops += length(gpu.draw_ops)
        stats.total_stencil_groups += length(gpu.stencil_groups)
        for (op in gpu.draw_ops) {
            if (op.stencil_idx >= 0) {
                stats.non_stencil_batches += 0  // stencil = 2 calls
            } else {
                stats.non_stencil_batches++
            }
        }
    }
    let stencil_calls = stats.total_stencil_groups * 2
    stats.avg_draw_calls_per_card = float(stencil_calls + stats.non_stencil_batches) / float(stats.total_cards)
    stats.last_frame_draws = card_stats_get_draws()
    stats.last_frame_draw_calls = card_stats_get_draw_calls()
    stats.last_frame_triangles = card_stats_get_triangles()
    return JV(stats)
}

struct CmdFocusArgs {
    card : string = ""
    zoom : float = 0.85
    offset_x : float = 0.0
    offset_y : float = 0.0
}

[live_command(description="Focus on a single card by name. Empty to show all. zoom=scale, offset_x/offset_y=pan.")]
def cmd_focus(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdFocusArgs>)
    if (length(args.card) == 0) {
        solo_mode = false
        solo_card_idx = -1
        solo_zoom = 0.85
        solo_offset = float2(0.0, 0.0)
        zoom_target = 0.0
        return JV("showing all cards")
    }
    let idx = find_card(gpu_deck, args.card)
    if (idx >= 0) {
        solo_mode = true
        solo_card_idx = idx
        solo_zoom = args.zoom
        solo_offset = float2(args.offset_x, args.offset_y)
        return JV("focused on {args.card}")
    }
    return JV("card not found: {args.card}")
}

[live_command(description="List loaded card names")]
def cmd_list_cards(input : JsonValue?) : JsonValue? {
    return JV(gpu_deck.names)
}

[live_command(description="Get last click coordinates (screen space)")]
def cmd_click_pos(input : JsonValue?) : JsonValue? {
    return JV("x={last_click_x} y={last_click_y} display={display_w}x{display_h}")
}

struct CmdDebugDrawArgs {
    skip : int = -1
    only : int = -1
}

[live_command(description="Debug: skip or isolate draw ops. skip=N skips op N, only=N draws only op N, both -1 resets.")]
def cmd_debug_draw(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdDebugDrawArgs>)
    return JV("skip={args.skip} only={args.only}")
}

struct CmdSaveViewArgs {
    file : string = "view.json"
}

struct ViewState {
    card_idx : int
    zoom : double
    offset_x : double
    offset_y : double
}

[live_command(description="Save current view position to a JSON file")]
def cmd_save_view(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdSaveViewArgs>)
    var fname = args.file
    if (empty(fname)) { fname = "view.json"; }
    let text = "\{\"card_idx\":{solo_card_idx},\"zoom\":{solo_zoom},\"offset_x\":{solo_offset.x},\"offset_y\":{solo_offset.y}\}"
    fopen(fname, "wb") <| $(f) {
        if (f != null) {
            fwrite(f, text)
        }
    }
    return JV("saved to {fname}: {text}")
}

[live_command(description="Load view position from a JSON file")]
def cmd_load_view(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdSaveViewArgs>)
    var fname = args.file
    if (empty(fname)) { fname = "view.json"; }
    var text = ""
    fopen(fname, "rb") <| $(f) {
        if (f != null) {
            text = fread(f)
        }
    }
    if (empty(text)) {
        return JV("file not found: {fname}")
    }
    var error = ""
    var data = read_json(text, error)
    if (data == null) {
        return JV("parse error: {error}")
    }
    let vs = from_JV(data, type<ViewState>)
    solo_mode = true
    solo_card_idx = vs.card_idx
    solo_zoom = float(vs.zoom)
    solo_offset = float2(float(vs.offset_x), float(vs.offset_y))
    return JV("loaded from {fname}: card={solo_card_idx} zoom={solo_zoom}")
}

// ============================================================================
// Lifecycle
// ============================================================================

[export]
def init() {
    live_create_window("Card Viewer", 1280, 800)
    renderer = create_card_renderer()
    gpu_deck <- load_gpu_deck()
    if (!gpu_deck.loaded) {
        to_log(LOG_ERROR, "card viewer: failed to load deck\n")
    }
    back_card_idx = find_card(gpu_deck, "back")
    build_layout()
    to_log(LOG_INFO, "card viewer: init (is_reload={is_reload()}, cards={card_count(gpu_deck)})\n")
}

[export]
def update() {
    if (!live_begin_frame()) {
        return
    }
    live_get_framebuffer_size(display_w, display_h)
    glViewport(0, 0, display_w, display_h)
    glClearColor(bg_color.x, bg_color.y, bg_color.z, 1.0)
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)
    gl_stats_reset()
    card_stats_reset()
    glDisable(GL_DEPTH_TEST)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    let dt = get_dt()
    let lay = compute_layout()

    // Mouse click detection
    let mouse_down = glfwGetMouseButton(live_window, GLFW_MOUSE_BUTTON_1) == int(GLFW_PRESS)
    let clicked = mouse_down && !mouse_was_pressed
    mouse_was_pressed = mouse_down

    let rmouse_down = glfwGetMouseButton(live_window, GLFW_MOUSE_BUTTON_2) == int(GLFW_PRESS)
    let rclicked = rmouse_down && !rmouse_was_pressed
    rmouse_was_pressed = rmouse_down

    // Right-click: in solo mode zoom 2x on click point, otherwise toggle 3D rotation
    if (rclicked) {
        if (solo_mode && solo_card_idx >= 0) {
            var mx, my : double
            glfwGetCursorPos(live_window, safe_addr(mx), safe_addr(my))
            let mxf = float(mx)
            let myf = float(my)
            last_click_x = mxf
            last_click_y = myf
            // offset so the clicked point becomes the center
            let cx = float(display_w) * 0.5
            let cy = float(display_h) * 0.5
            // adjust existing offset: new_offset = (old_offset + center - click) * 2
            // but simpler: just accumulate the delta and halve the zoom
            solo_offset = float2(
                (solo_offset.x + cx - mxf) * 2.0,
                (solo_offset.y + cy - myf) * 2.0
            )
            solo_zoom *= 2.0
        } elif (zoom_target > 0.5) {
            rotating = !rotating
            if (!rotating) {
                rotate_angle = 0.0
            }
        }
    }

    if (clicked) {
        var mx, my : double
        glfwGetCursorPos(live_window, safe_addr(mx), safe_addr(my))
        let mxf = float(mx)
        let myf = float(my)
        last_click_x = mxf
        last_click_y = myf

        if (zoom_target > 0.5) {
            // clicking while zoomed → start unzoom
            zoom_target = 0.0
            rotating = false
            rotate_angle = 0.0
        } else {
            // hit test against grid
            for (r in range(length(rows))) {
                for (c in range(length(rows[r]))) {
                    let pos = card_grid_pos(lay, r, c, length(rows[r]))
                    if (mxf >= pos.x && mxf <= pos.x + lay.card_w && myf >= pos.y && myf <= pos.y + lay.card_h) {
                        zoom_card = rows[r][c]
                        zoom_row = r
                        zoom_col = c
                        zoom_target = 1.0
                    }
                }
            }
        }
    }

    // Escape to zoom out
    if (glfwGetKey(live_window, int(GLFW_KEY_ESCAPE)) == int(GLFW_PRESS)) {
        zoom_target = 0.0
    }

    // Animate zoom
    zoom_t = zoom_t + (zoom_target - zoom_t) * min(zoom_speed * dt, 1.0)
    if (abs(zoom_t - zoom_target) < 0.001) {
        zoom_t = zoom_target
        if (zoom_t == 0.0) {
            // animation finished — clear card
            zoom_card = -1
            zoom_row = -1
            zoom_col = -1
        }
    }

    // Advance rotation
    if (rotating) {
        rotate_angle += rotate_speed * dt
    }

    // Compute zoomed card position & scale
    let zoom_scale = lay.scale + (min(float(display_w) / CARD_DOC_WIDTH, float(display_h) / CARD_DOC_HEIGHT) * 0.9 - lay.scale) * zoom_t
    let zoom_cs = card_size(zoom_scale)
    let center_x = (float(display_w) - zoom_cs.x) * 0.5
    let center_y = (float(display_h) - zoom_cs.y) * 0.5

    // Solo debug mode — just one card centered, no grid
    if (solo_mode && solo_card_idx >= 0) {
        let solo_scale = min(float(display_w) / CARD_DOC_WIDTH, float(display_h) / CARD_DOC_HEIGHT) * solo_zoom
        let solo_cs = card_size(solo_scale)
        let sx = (float(display_w) - solo_cs.x) * 0.5 + solo_offset.x
        let sy = (float(display_h) - solo_cs.y) * 0.5 + solo_offset.y
        draw_card(renderer, gpu_deck, solo_card_idx, sx, sy, solo_scale, display_w, display_h)
        glDisable(GL_BLEND)
        live_end_frame()
        return
    }

    // Draw all cards
    for (r in range(length(rows))) {
        let num_in_row = length(rows[r])
        for (c in range(num_in_row)) {
            let idx = rows[r][c]
            if (idx < 0) {
                continue
            }
            let grid_pos = card_grid_pos(lay, r, c, num_in_row)
            let is_focus = (idx == zoom_card && r == zoom_row && c == zoom_col)

            if (is_focus) {
                // draw focused card last (on top)
                continue
            }

            // darken non-focused cards when zooming in
            let dim = 1.0 - zoom_t * 0.7
            draw_card(renderer, gpu_deck, idx, grid_pos.x, grid_pos.y, lay.scale, display_w, display_h, float4(dim, dim, dim, 1.0))
        }
    }

    // Draw focused card on top with interpolated position
    if (zoom_card >= 0 && zoom_row >= 0 && zoom_col >= 0) {
        let grid_pos = card_grid_pos(lay, zoom_row, zoom_col, length(rows[zoom_row]))
        let fx = grid_pos.x + (center_x - grid_pos.x) * zoom_t
        let fy = grid_pos.y + (center_y - grid_pos.y) * zoom_t
        let fs = lay.scale + (zoom_scale - lay.scale) * zoom_t
        // Always apply perspective when zoomed so size is consistent with/without rotation
        let aspect = float(display_w) / float(display_h)
        let fov = radians(45.0)
        let dist = 2.5
        let proj = perspective_rh_opengl(fov, aspect, 0.1, 10.0)
        let half_h = dist * tan(fov * 0.5)
        let half_w = half_h * aspect
        let correction = compose(float3(0.0), float4(0.0, 0.0, 0.0, 1.0), float3(half_w, half_h, 1.0))
        var draw_idx = zoom_card
        var rot = float4(0.0, 0.0, 0.0, 1.0)  // identity quaternion
        var sx = 1.0
        if (rotate_angle != 0.0) {
            let axis = normalize(float3(rotate_tilt * sin(rotate_angle), 1.0, 0.0))
            rot = quat_from_unit_vec_ang(axis, rotate_angle)
            let facing_back = cos(rotate_angle) < 0.0
            if (facing_back && back_card_idx >= 0) {
                draw_idx = back_card_idx
            }
            sx = facing_back ? -1.0 : 1.0
        }
        let model = compose(float3(0.0, 0.0, -dist), rot, float3(sx, 1.0, 1.0))
        // Blend from identity (grid) to full perspective (zoomed)
        let persp = correction * proj * model
        var extra : float4x4
        let id = identity4x4()
        extra[0] = float4(id[0].x + (persp[0].x - id[0].x) * zoom_t, id[0].y + (persp[0].y - id[0].y) * zoom_t, id[0].z + (persp[0].z - id[0].z) * zoom_t, id[0].w + (persp[0].w - id[0].w) * zoom_t)
        extra[1] = float4(id[1].x + (persp[1].x - id[1].x) * zoom_t, id[1].y + (persp[1].y - id[1].y) * zoom_t, id[1].z + (persp[1].z - id[1].z) * zoom_t, id[1].w + (persp[1].w - id[1].w) * zoom_t)
        extra[2] = float4(id[2].x + (persp[2].x - id[2].x) * zoom_t, id[2].y + (persp[2].y - id[2].y) * zoom_t, id[2].z + (persp[2].z - id[2].z) * zoom_t, id[2].w + (persp[2].w - id[2].w) * zoom_t)
        extra[3] = float4(id[3].x + (persp[3].x - id[3].x) * zoom_t, id[3].y + (persp[3].y - id[3].y) * zoom_t, id[3].z + (persp[3].z - id[3].z) * zoom_t, id[3].w + (persp[3].w - id[3].w) * zoom_t)
        draw_card(renderer, gpu_deck, draw_idx, fx, fy, fs, display_w, display_h, float4(1.0, 1.0, 1.0, 1.0), extra)
    }

    gl_render_stats.draw_calls += card_stats_get_draw_calls()
    gl_render_stats.triangles += card_stats_get_triangles()
    glDisable(GL_BLEND)
    live_end_frame()
}

[export]
def shutdown() {
    to_log(LOG_INFO, "card viewer: shutdown\n")
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
