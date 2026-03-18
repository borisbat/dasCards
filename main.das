options gen2
options no_aot
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
require daslib/defer
require daslib/safe_addr
require daslib/math_boost
require daslib/json
require daslib/json_boost
require live_host

require strings
require cards/card_mesh

// ============================================================================
// Vertex format
// ============================================================================

[vertex_buffer]
struct CardVertex {
    xy    : float2
    color : float4
}

// ============================================================================
// Shaders
// ============================================================================

var @in @location = 0 v_xy    : float2
var @in @location = 1 v_color : float4
var @uniform v_mvp : float4x4
var @inout f_color : float4
var @out f_FragColor : float4

[vertex_program]
def vs_card {
    f_color = v_color
    gl_Position = v_mvp * float4(v_xy, 0.0, 1.0)
}

[fragment_program]
def fs_card {
    f_FragColor = f_color
}

// ============================================================================
// GPU card data — parallel arrays
// ============================================================================

struct GpuMeshBatch {
    vao : uint
    vbo : uint
    ebo : uint
    num_indices : int
}

struct GpuStencilGroup {
    contour_batch : GpuMeshBatch  // all contour triangles merged
    cover_batch : GpuMeshBatch    // bounding box quad for cover pass
    color : float4
    evenodd : bool = false
}

// A draw operation: either a regular mesh batch or a stencil group
struct GpuDrawOp {
    batch : GpuMeshBatch          // for regular meshes
    stencil_idx : int = -1        // -1 = use batch, >=0 = use stencil_groups[idx]
}

struct GpuCard {
    draw_ops : array<GpuDrawOp>
    stencil_groups : array<GpuStencilGroup>
    min_pt : float2
    max_pt : float2
}

var gpu_cards : array<GpuCard>
var card_names : array<string>
var deck : CardDeck

// Card bounds in document space (after group + use x/y transforms)
let CARD_MIN = float2(1.25, 1.25)
let CARD_MAX = float2(167.825, 243.39)

// ============================================================================
// State
// ============================================================================

var program : uint
var display_w = 0
var display_h = 0

var @live scroll_y = 0.0
var @live card_scale = 0.55
var @live bg_color = float3(0.08, 0.12, 0.08)

let CARD_PADDING = 6.0
let CARDS_PER_ROW = 13

// ============================================================================
// Upload card meshes to GPU
// ============================================================================

def upload_mesh_batch(vertices : array<CardVertex>; indices : array<int>) : GpuMeshBatch {
    var batch = GpuMeshBatch()
    batch.num_indices = length(indices)
    if (length(indices) > 0) {
        glGenVertexArrays(1, safe_addr(batch.vao))
        glBindVertexArray(batch.vao)
        glGenBuffers(1, safe_addr(batch.vbo))
        glBindBuffer(GL_ARRAY_BUFFER, batch.vbo)
        glBufferData(GL_ARRAY_BUFFER, vertices, GL_STATIC_DRAW)
        bind_vertex_buffer(null, type<CardVertex>)
        glGenBuffers(1, safe_addr(batch.ebo))
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, batch.ebo)
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices, GL_STATIC_DRAW)
        glBindVertexArray(0u)
    }
    return <- batch
}

def upload_stencil_group(sg : StencilGroup) : GpuStencilGroup {
    var gsg = GpuStencilGroup(color = sg.color, evenodd = sg.evenodd)
    var sg_verts : array<CardVertex>
    var sg_idxs : array<int>
    var sg_base = 0
    for (c in sg.contours) {
        for (v in c.vertices) {
            sg_verts |> push(CardVertex(xy = v, color = sg.color))
        }
        for (idx in c.indices) {
            sg_idxs |> push(idx + sg_base)
        }
        sg_base += length(c.vertices)
    }
    gsg.contour_batch <- upload_mesh_batch(sg_verts, sg_idxs)
    // Cover quad (bounding box)
    var cover_verts : array<CardVertex>
    var cover_idxs : array<int>
    let mn = sg.min_pt
    let mx = sg.max_pt
    cover_verts |> push(CardVertex(xy = float2(mn.x, mn.y), color = sg.color))
    cover_verts |> push(CardVertex(xy = float2(mx.x, mn.y), color = sg.color))
    cover_verts |> push(CardVertex(xy = float2(mx.x, mx.y), color = sg.color))
    cover_verts |> push(CardVertex(xy = float2(mn.x, mx.y), color = sg.color))
    cover_idxs |> push(0)
    cover_idxs |> push(1)
    cover_idxs |> push(2)
    cover_idxs |> push(0)
    cover_idxs |> push(2)
    cover_idxs |> push(3)
    gsg.cover_batch <- upload_mesh_batch(cover_verts, cover_idxs)
    return <- gsg
}

def upload_card(card : CardMesh) : GpuCard {
    var gpu = GpuCard(min_pt = float2(1e9, 1e9), max_pt = float2(-1e9, -1e9))
    // Process draw order: batch consecutive regular meshes, upload stencil groups inline
    var pending_verts : array<CardVertex>
    var pending_idxs : array<int>
    var pending_base = 0
    for (op in card.draw_order) {
        if (op.mesh_idx >= 0) {
            // Accumulate regular mesh into pending batch
            let mesh & = unsafe(card.meshes[op.mesh_idx])
            for (v in mesh.vertices) {
                pending_verts |> push(CardVertex(xy = v, color = mesh.color))
                gpu.min_pt = float2(min(gpu.min_pt.x, v.x), min(gpu.min_pt.y, v.y))
                gpu.max_pt = float2(max(gpu.max_pt.x, v.x), max(gpu.max_pt.y, v.y))
            }
            for (idx in mesh.indices) {
                pending_idxs |> push(idx + pending_base)
            }
            pending_base += length(mesh.vertices)
        } elif (op.stencil_idx >= 0) {
            // Flush pending regular meshes first
            if (length(pending_idxs) > 0) {
                var draw_op = GpuDrawOp()
                draw_op.batch <- upload_mesh_batch(pending_verts, pending_idxs)
                gpu.draw_ops |> emplace(draw_op)
                pending_verts |> clear()
                pending_idxs |> clear()
                pending_base = 0
            }
            // Upload stencil group
            let sg & = unsafe(card.stencil_groups[op.stencil_idx])
            gpu.min_pt = float2(min(gpu.min_pt.x, sg.min_pt.x), min(gpu.min_pt.y, sg.min_pt.y))
            gpu.max_pt = float2(max(gpu.max_pt.x, sg.max_pt.x), max(gpu.max_pt.y, sg.max_pt.y))
            var stencil_draw_op = GpuDrawOp(stencil_idx = length(gpu.stencil_groups))
            gpu.stencil_groups |> emplace(upload_stencil_group(sg))
            gpu.draw_ops |> emplace(stencil_draw_op)
        }
    }
    // Flush remaining regular meshes
    if (length(pending_idxs) > 0) {
        var draw_op = GpuDrawOp()
        draw_op.batch <- upload_mesh_batch(pending_verts, pending_idxs)
        gpu.draw_ops |> emplace(draw_op)
    }
    return <- gpu
}

def is_playing_card(name : string) : bool {
    // Filter to actual playing cards: {suit}_{rank}, joker_black, joker_red, back
    if (name == "back" || name == "joker_black" || name == "joker_red") {
        return true
    }
    return starts_with(name, "club_") || starts_with(name, "diamond_") || starts_with(name, "heart_") || starts_with(name, "spade_")
}

def upload_all_cards() {
    card_names |> clear()
    gpu_cards |> clear()
    var all_names : array<string>
    for (kv in keys(deck.cards)) {
        all_names |> push(clone_string(kv))
    }
    sort(all_names)
    for (name in all_names) {
        if (is_playing_card(name)) {
            card_names |> push(clone_string(name))
            deck.cards |> get(name) <| $(card) {
                gpu_cards |> emplace(upload_card(card))
            }
        }
    }
    print("Uploaded {length(gpu_cards)} playing cards to GPU\n")
}

// ============================================================================
// Drawing
// ============================================================================

def make_card_mvp(x, y, scale : float) : float4x4 {
    let w = float(display_w)
    let h = float(display_h)
    var mvp : float4x4
    mvp[0] = float4(2.0 * scale / w, 0.0, 0.0, 0.0)
    mvp[1] = float4(0.0, -2.0 * scale / h, 0.0, 0.0)
    mvp[2] = float4(0.0, 0.0, 1.0, 0.0)
    mvp[3] = float4((2.0 / w) * (x - scale * CARD_MIN.x) - 1.0,
                    1.0 - (2.0 / h) * (y - scale * CARD_MIN.y),
                    0.0, 1.0)
    return mvp
}

def draw_batch(batch : GpuMeshBatch; mvp : float4x4) {
    if (batch.num_indices == 0) {
        return
    }
    v_mvp = mvp
    vs_card_bind_uniform(program)
    glBindVertexArray(batch.vao)
    glDrawElements(GL_TRIANGLES, batch.num_indices, GL_UNSIGNED_INT, null)
}

def draw_stencil_group(sg : GpuStencilGroup; mvp : float4x4) {
    if (sg.contour_batch.num_indices == 0) {
        return
    }
    // Step 1: Stencil pass — render all contour triangles into stencil buffer
    glEnable(GL_STENCIL_TEST)
    glStencilMask(0xFFu)
    glClear(GL_STENCIL_BUFFER_BIT)
    glColorMask(false, false, false, false)
    glStencilFunc(GL_ALWAYS, 0, 0xFFu)
    if (sg.evenodd) {
        glStencilOp(GL_KEEP, GL_KEEP, GL_INVERT)
    } else {
        // Nonzero winding: Y-flip in MVP reverses screen winding
        glStencilOpSeparate(GL_FRONT, GL_KEEP, GL_KEEP, GL_DECR_WRAP)
        glStencilOpSeparate(GL_BACK, GL_KEEP, GL_KEEP, GL_INCR_WRAP)
    }
    draw_batch(sg.contour_batch, mvp)
    // Step 2: Cover pass — draw bounding box quad where stencil != 0
    glColorMask(true, true, true, true)
    glStencilFunc(GL_NOTEQUAL, 0, 0xFFu)
    glStencilOp(GL_KEEP, GL_KEEP, uint(0))  // GL_ZERO
    draw_batch(sg.cover_batch, mvp)
    glDisable(GL_STENCIL_TEST)
}

def draw_card_at(idx : int; x, y, scale : float) {
    let gpu & = unsafe(gpu_cards[idx])
    let mvp = make_card_mvp(x, y, scale)
    // Draw ops in SVG order (regular batches interleaved with stencil groups)
    for (op in gpu.draw_ops) {
        if (op.stencil_idx >= 0) {
            draw_stencil_group(gpu.stencil_groups[op.stencil_idx], mvp)
        } else {
            draw_batch(op.batch, mvp)
        }
    }
}

// ============================================================================
// Live commands
// ============================================================================

struct CmdScaleArgs {
    scale : float = 0.55
}

struct CmdFocusArgs {
    card : string = ""
}

var @live focus_card = -1

[live_command(description="Set card scale. Args: scale (float)")]
def cmd_set_scale(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdScaleArgs>)
    card_scale = args.scale
    return JV("scale={card_scale}")
}

[live_command(description="List loaded card names")]
def cmd_list_cards(input : JsonValue?) : JsonValue? {
    return JV(card_names)
}

[live_command(description="Focus on a single card by name. Empty to show all.")]
def cmd_focus(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdFocusArgs>)
    if (length(args.card) == 0) {
        focus_card = -1
        return JV("showing all cards")
    }
    for (i in range(length(card_names))) {
        if (card_names[i] == args.card) {
            focus_card = i
            return JV("focused on {args.card} (index {i})")
        }
    }
    return JV("card not found: {args.card}")
}

[live_command(description="Dump card info by name or index")]
def cmd_card_info(input : JsonValue?) : JsonValue? {
    let args = from_JV(input, type<CmdFocusArgs>)
    var idx = -1
    if (length(args.card) > 0) {
        for (i in range(length(card_names))) {
            if (card_names[i] == args.card) {
                idx = i
                break
            }
        }
    }
    if (idx < 0) {
        idx = 0
    }
    var lines : array<string>
    let gpu & = unsafe(gpu_cards[idx])
    lines |> push("{card_names[idx]}: min=({gpu.min_pt.x},{gpu.min_pt.y}) max=({gpu.max_pt.x},{gpu.max_pt.y})")
    lines |> push("draw_ops: {length(gpu.draw_ops)}, stencil_groups: {length(gpu.stencil_groups)}")
    for (i in range(length(gpu.draw_ops))) {
        let op & = unsafe(gpu.draw_ops[i])
        if (op.stencil_idx >= 0) {
            let sg & = unsafe(gpu.stencil_groups[op.stencil_idx])
            lines |> push("  op[{i}]: stencil contour_idx={sg.contour_batch.num_indices} cover={sg.cover_batch.num_indices} eo={sg.evenodd}")
        } else {
            lines |> push("  op[{i}]: batch indices={op.batch.num_indices}")
        }
    }
    return JV(lines)
}

// ============================================================================
// Lifecycle
// ============================================================================

[export]
def init() {
    live_create_window("Card Viewer", 1280, 800)
    program = cache_shader_program(vs_card`shader_text, fs_card`shader_text)
    deck <- load_deck("cards/svg-cards.svg")
    upload_all_cards()
    print("card viewer: init (is_reload={is_reload()}, cards={length(card_names)})\n")
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

    // Lay out cards in a grid using standard card-base dimensions
    let card_w = (CARD_MAX.x - CARD_MIN.x) * card_scale
    let card_h = (CARD_MAX.y - CARD_MIN.y) * card_scale
    let grid_w = card_w + CARD_PADDING
    let grid_h = card_h + CARD_PADDING
    let start_x = CARD_PADDING
    let start_y = CARD_PADDING - scroll_y

    glUseProgram(program)
    if (focus_card >= 0 && focus_card < length(gpu_cards)) {
        // Single card centered on screen
        let cx = (float(display_w) - card_w) * 0.5
        let cy = (float(display_h) - card_h) * 0.5
        draw_card_at(focus_card, cx, cy, card_scale)
    } else {
        for (i in range(length(card_names))) {
            let col = i % CARDS_PER_ROW
            let row = i / CARDS_PER_ROW
            let x = start_x + float(col) * grid_w
            let y = start_y + float(row) * grid_h
            if (y + card_h < 0.0 || y > float(display_h)) {
                continue
            }
            draw_card_at(i, x, y, card_scale)
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

// Dual-mode: also works with regular daslang.exe
[export]
def main() {
    init()
    while (!exit_requested()) {
        update()
    }
    shutdown()
}
