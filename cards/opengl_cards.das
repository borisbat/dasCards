options gen2
options persistent_heap

module opengl_cards public

require opengl/opengl_boost
require opengl/opengl_cache
require daslib/safe_addr
require math public
require daslib/math_boost
require card_mesh
require strings
require fio

let CARDS_DIR = dir_name(get_module_file_name("opengl_cards"))

// ============================================================================
// Card dimensions (SVG document space)
// ============================================================================

let CARD_DOC_MIN = float2(1.25, 1.25)
let CARD_DOC_MAX = float2(167.825, 243.39)
let CARD_DOC_WIDTH = CARD_DOC_MAX.x - CARD_DOC_MIN.x
let CARD_DOC_HEIGHT = CARD_DOC_MAX.y - CARD_DOC_MIN.y

// ============================================================================
// Vertex format and shaders
// ============================================================================

[vertex_buffer]
struct CardVertex {
    xy    : float2
    color : float4
}

var @in @location = 0 v_xy    : float2
var @in @location = 1 v_color : float4
var @uniform v_mvp : float4x4
var @uniform v_tint : float4
var @inout f_color : float4
var @out f_FragColor : float4

[vertex_program]
def vs_card {
    f_color = float4(v_color.xyz * v_tint.xyz, v_color.w * v_tint.w)
    gl_Position = v_mvp * float4(v_xy, 0.0, 1.0)
}

[fragment_program]
def fs_card {
    f_FragColor = f_color
}

// ============================================================================
// GPU data types
// ============================================================================

struct GpuMeshBatch {
    vao : uint
    vbo : uint
    ebo : uint
    num_indices : int
}

struct GpuStencilGroup {
    contour_batch : GpuMeshBatch
    cover_batch : GpuMeshBatch
    color : float4
    evenodd : bool = false
}

struct GpuDrawOp {
    batch : GpuMeshBatch
    stencil_idx : int = -1
}

struct GpuCard {
    draw_ops : array<GpuDrawOp>
    stencil_groups : array<GpuStencilGroup>
}

struct CardRenderer {
    program : uint
}

struct GpuDeck {
    cards : array<GpuCard>
    names : array<string>
    loaded : bool = false
}

// ============================================================================
// Public API
// ============================================================================

def create_card_renderer() : CardRenderer {
    return CardRenderer(program = cache_shader_program(vs_card`shader_text, fs_card`shader_text))
}

def load_gpu_deck() : GpuDeck {
    let svg_path = "{CARDS_DIR}/svg-cards.svg"
    var deck <- load_deck(svg_path)
    var gpu_deck = GpuDeck()
    if (!deck.loaded) {
        to_log(LOG_ERROR, "load_gpu_deck: failed to load '{svg_path}'\n")
        return <- gpu_deck
    }
    var all_names : array<string>
    for (kv in keys(deck.cards)) {
        all_names |> push(clone_string(kv))
    }
    sort(all_names)
    for (name in all_names) {
        if (is_playing_card(name)) {
            gpu_deck.names |> push(clone_string(name))
            deck.cards |> get(name) <| $(card) {
                gpu_deck.cards |> emplace(upload_card(card))
            }
        }
    }
    gpu_deck.loaded = true
    return <- gpu_deck
}

// Find card index by name. Returns -1 if not found.
// Names are sorted alphabetically. Format: "{suit}_{rank}" where suit is
// club/diamond/heart/spade, rank is 1 (ace), 2-10, jack, queen, king.
// Special cards: "back", "alternate-back", "joker_black", "joker_red".
// All names available in deck.names array.
def find_card(deck : GpuDeck; name : string) : int {
    for (i in range(length(deck.names))) {
        if (deck.names[i] == name) {
            return i
        }
    }
    return -1
}

def card_count(deck : GpuDeck) : int {
    return length(deck.cards)
}

def card_size(scale : float) : float2 {
    return float2(CARD_DOC_WIDTH * scale, CARD_DOC_HEIGHT * scale)
}

// Draw a single card with optional tint. tint.xyz multiplies color, tint.w multiplies alpha.
// Default float4(1,1,1,1) = no tint. Use float4(0.3,0.3,0.3,1) to darken, float4(1,1,1,0.5) to fade.
// extra: optional 4x4 transform applied after model→clip (use for 3D rotation etc.)
def draw_card(renderer : CardRenderer; deck : GpuDeck; index : int; x, y, scale : float; screen_w, screen_h : int; tint : float4 = float4(1.0, 1.0, 1.0, 1.0); extra : float4x4 = identity4x4()) {
    if (index < 0 || index >= length(deck.cards)) {
        return
    }
    let gpu & = unsafe(deck.cards[index])
    let mvp = extra * make_card_mvp(x, y, scale, screen_w, screen_h)
    glUseProgram(renderer.program)
    v_tint = tint
    for (op in gpu.draw_ops) {
        if (op.stencil_idx >= 0) {
            draw_stencil_group(gpu.stencil_groups[op.stencil_idx], mvp, renderer.program)
        } else {
            draw_batch(op.batch, mvp, renderer.program)
        }
    }
}

def is_playing_card(name : string) : bool {
    if (name == "back" || name == "alternate-back" || name == "joker_black" || name == "joker_red") {
        return true
    }
    return starts_with(name, "club_") || starts_with(name, "diamond_") || starts_with(name, "heart_") || starts_with(name, "spade_")
}

// ============================================================================
// Internal — upload
// ============================================================================

def private upload_mesh_batch(vertices : array<CardVertex>; indices : array<int>) : GpuMeshBatch {
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

def private upload_stencil_group(sg : StencilGroup) : GpuStencilGroup {
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

def private upload_card(card : CardMesh) : GpuCard {
    var gpu : GpuCard
    var pending_verts : array<CardVertex>
    var pending_idxs : array<int>
    var pending_base = 0
    for (op in card.draw_order) {
        if (op.mesh_idx >= 0) {
            let mesh & = unsafe(card.meshes[op.mesh_idx])
            for (v in mesh.vertices) {
                pending_verts |> push(CardVertex(xy = v, color = mesh.color))
            }
            for (idx in mesh.indices) {
                pending_idxs |> push(idx + pending_base)
            }
            pending_base += length(mesh.vertices)
        } elif (op.stencil_idx >= 0) {
            if (length(pending_idxs) > 0) {
                var draw_op = GpuDrawOp()
                draw_op.batch <- upload_mesh_batch(pending_verts, pending_idxs)
                gpu.draw_ops |> emplace(draw_op)
                pending_verts |> clear()
                pending_idxs |> clear()
                pending_base = 0
            }
            let sg & = unsafe(card.stencil_groups[op.stencil_idx])
            var stencil_draw_op = GpuDrawOp(stencil_idx = length(gpu.stencil_groups))
            gpu.stencil_groups |> emplace(upload_stencil_group(sg))
            gpu.draw_ops |> emplace(stencil_draw_op)
        }
    }
    if (length(pending_idxs) > 0) {
        var draw_op = GpuDrawOp()
        draw_op.batch <- upload_mesh_batch(pending_verts, pending_idxs)
        gpu.draw_ops |> emplace(draw_op)
    }
    return <- gpu
}

// ============================================================================
// Internal — draw
// ============================================================================

def private make_card_mvp(x, y, scale : float; screen_w, screen_h : int) : float4x4 {
    let w = float(screen_w)
    let h = float(screen_h)
    var mvp : float4x4
    mvp[0] = float4(2.0 * scale / w, 0.0, 0.0, 0.0)
    mvp[1] = float4(0.0, -2.0 * scale / h, 0.0, 0.0)
    mvp[2] = float4(0.0, 0.0, 1.0, 0.0)
    mvp[3] = float4((2.0 / w) * (x - scale * CARD_DOC_MIN.x) - 1.0,
                    1.0 - (2.0 / h) * (y - scale * CARD_DOC_MIN.y),
                    0.0, 1.0)
    return mvp
}

def private draw_batch(batch : GpuMeshBatch; mvp : float4x4; prog : uint) {
    if (batch.num_indices == 0) {
        return
    }
    v_mvp = mvp
    vs_card_bind_uniform(prog)
    glBindVertexArray(batch.vao)
    glDrawElements(GL_TRIANGLES, batch.num_indices, GL_UNSIGNED_INT, null)
}

def private draw_stencil_group(sg : GpuStencilGroup; mvp : float4x4; prog : uint) {
    if (sg.contour_batch.num_indices == 0) {
        return
    }
    glEnable(GL_STENCIL_TEST)
    glStencilMask(0xFFu)
    glClear(GL_STENCIL_BUFFER_BIT)
    glColorMask(false, false, false, false)
    glStencilFunc(GL_ALWAYS, 0, 0xFFu)
    if (sg.evenodd) {
        glStencilOp(GL_KEEP, GL_KEEP, GL_INVERT)
    } else {
        glStencilOpSeparate(GL_FRONT, GL_KEEP, GL_KEEP, GL_DECR_WRAP)
        glStencilOpSeparate(GL_BACK, GL_KEEP, GL_KEEP, GL_INCR_WRAP)
    }
    draw_batch(sg.contour_batch, mvp, prog)
    glColorMask(true, true, true, true)
    glStencilFunc(GL_NOTEQUAL, 0, 0xFFu)
    glStencilOp(GL_KEEP, GL_KEEP, uint(0))
    draw_batch(sg.cover_batch, mvp, prog)
    glDisable(GL_STENCIL_TEST)
}
