options gen2
options no_aot
options persistent_heap

require math
require strings
require pugixml/PUGIXML_boost
require svg_path
require earcut

// ============================================================================
// Card mesh data types
// ============================================================================

struct ColoredMesh {
    vertices : array<float2>
    indices : array<int>
    color : float4
}

// A group of contour meshes that must be rendered with stencil fill-rule
struct StencilGroup {
    contours : array<ColoredMesh>  // each contour tessellated independently
    color : float4
    min_pt : float2
    max_pt : float2
    evenodd : bool = false
}

// Draw operation: either a regular mesh or a stencil group (maintains SVG draw order)
struct DrawOp {
    mesh_idx : int = -1       // index into meshes[] (-1 if stencil)
    stencil_idx : int = -1    // index into stencil_groups[] (-1 if regular)
}

struct CardMesh {
    meshes : array<ColoredMesh>
    stencil_groups : array<StencilGroup>
    draw_order : array<DrawOp>
}

def add_mesh(var result : CardMesh; var cm : ColoredMesh) {
    result.draw_order |> push(DrawOp(mesh_idx = length(result.meshes)))
    result.meshes |> emplace(cm)
}

def add_stencil_group(var result : CardMesh; var sg : StencilGroup) {
    result.draw_order |> push(DrawOp(stencil_idx = length(result.stencil_groups)))
    result.stencil_groups |> emplace(sg)
}

struct SvgShapePath {
    d : string
    fill : float4
    xform : Xform2D = Xform2D()  // accumulated transform from component group hierarchy + path transform
    evenodd : bool = false
    has_explicit_fill : bool = false  // true if fill was set on the element, false if inherited
}

struct SvgComponent {
    id : string
    paths : array<SvgShapePath>
}

struct Xform2D {
    a : float = 1.0  // scale x / rotation
    b : float = 0.0
    c : float = 0.0
    d : float = 1.0  // scale y / rotation
    e : float = 0.0  // translate x
    f : float = 0.0  // translate y
}

struct CardDeck {
    components : table<string; SvgComponent>
    cards : table<string; CardMesh>
}

// ============================================================================
// Color parsing
// ============================================================================

def hex_digit(ch : int) : int {
    if (ch >= '0' && ch <= '9') {
        return ch - '0'
    } elif (ch >= 'a' && ch <= 'f') {
        return ch - 'a' + 10
    } elif (ch >= 'A' && ch <= 'F') {
        return ch - 'A' + 10
    }
    return 0
}

def parse_hex_color(s : string) : float4 {
    if (length(s) == 0 || character_at(s, 0) != '#') {
        if (s == "none") {
            return float4(0.0, 0.0, 0.0, 0.0)
        }
        return float4(0.0, 0.0, 0.0, 1.0)
    }
    let len = length(s)
    if (len == 7) {
        let r = hex_digit(character_at(s, 1)) * 16 + hex_digit(character_at(s, 2))
        let g = hex_digit(character_at(s, 3)) * 16 + hex_digit(character_at(s, 4))
        let b = hex_digit(character_at(s, 5)) * 16 + hex_digit(character_at(s, 6))
        return float4(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0, 1.0)
    } elif (len == 4) {
        let r = hex_digit(character_at(s, 1))
        let g = hex_digit(character_at(s, 2))
        let b = hex_digit(character_at(s, 3))
        return float4(float(r) / 15.0, float(g) / 15.0, float(b) / 15.0, 1.0)
    }
    return float4(0.0, 0.0, 0.0, 1.0)
}

def extract_fill_from_style(style : string) : float4 {
    let idx = find(style, "fill:")
    if (idx < 0) {
        return float4(0.0, 0.0, 0.0, 1.0)
    }
    let start = idx + 5
    var end_idx = find(style, ";", start)
    if (end_idx < 0) {
        end_idx = length(style)
    }
    return parse_hex_color(slice(style, start, end_idx))
}

def get_fill_color(node : auto; parent_fill : float4) : float4 {
    let style = node_attr(node, "style", "")
    if (length(style) > 0 && find(style, "fill:") >= 0) {
        return extract_fill_from_style(style)
    }
    let fill_attr = node_attr(node, "fill", "")
    if (length(fill_attr) > 0) {
        return parse_hex_color(fill_attr)
    }
    return parent_fill
}

// ============================================================================
// Transform parsing
// ============================================================================

def parse_transform(s : string) : Xform2D {
    var result = Xform2D()
    if (length(s) == 0) {
        return result
    }
    var idx = find(s, "matrix(")
    if (idx >= 0) {
        var p = make_parser(slice(s, idx + 7))
        result.a = parse_number(p)
        result.b = parse_number(p)
        result.c = parse_number(p)
        result.d = parse_number(p)
        result.e = parse_number(p)
        result.f = parse_number(p)
        return result
    }
    idx = find(s, "translate(")
    if (idx >= 0) {
        var p = make_parser(slice(s, idx + 10))
        result.e = parse_number(p)
        if (has_more_numbers(p)) {
            result.f = parse_number(p)
        }
    }
    idx = find(s, "scale(")
    if (idx >= 0) {
        var p = make_parser(slice(s, idx + 6))
        result.a = parse_number(p)
        result.d = result.a
        if (has_more_numbers(p)) {
            result.d = parse_number(p)
        }
    }
    idx = find(s, "rotate(")
    if (idx >= 0) {
        var p = make_parser(slice(s, idx + 7))
        let angle = parse_number(p) * PI / 180.0
        let cos_a = cos(angle)
        let sin_a = sin(angle)
        result.a = cos_a
        result.b = sin_a
        result.c = -sin_a
        result.d = cos_a
    }
    return result
}

def xform_point(pt : float2; m : Xform2D) : float2 {
    return float2(m.a * pt.x + m.c * pt.y + m.e, m.b * pt.x + m.d * pt.y + m.f)
}

def xform_translate(tx, ty : float) : Xform2D {
    var r = Xform2D()
    r.e = tx
    r.f = ty
    return <- r
}

def xform_compose(outer, inner : Xform2D) : Xform2D {
    // outer * inner — apply inner first, then outer
    var r = Xform2D()
    r.a = outer.a * inner.a + outer.c * inner.b
    r.b = outer.b * inner.a + outer.d * inner.b
    r.c = outer.a * inner.c + outer.c * inner.d
    r.d = outer.b * inner.c + outer.d * inner.d
    r.e = outer.a * inner.e + outer.c * inner.f + outer.e
    r.f = outer.b * inner.e + outer.d * inner.f + outer.f
    return <- r
}

// ============================================================================
// SVG loading
// ============================================================================

def has_use_child(node : auto) : bool {
    for (u in each_child(node, "use")) {
        return true
    }
    return false
}

def collect_components_recursive(node : auto; var deck : CardDeck; parent_fill : float4) {
    for (g in each_child(node, "g")) {
        let id = node_attr(g, "id", "")
        if (length(id) > 0 && !has_use_child(g)) {
            var comp : SvgComponent
            comp.id = clone_string(id)
            // Pass the group's own transform as the starting transform for its paths
            let g_xform_str = node_attr(g, "transform", "")
            let g_xform = length(g_xform_str) > 0 ? parse_transform(g_xform_str) : Xform2D()
            collect_paths(g, comp, parent_fill, g_xform)
            if (length(comp.paths) > 0) {
                deck.components[clone_string(id)] := comp
            }
        }
        // recurse into nested groups to find deeply-nested simple components
        collect_components_recursive(g, deck, parent_fill)
    }
}

def load_svg_components(svg_file : string; var deck : CardDeck) {
    open_xml(svg_file) <| $(doc, ok) {
        if (!ok) {
            print("Failed to open SVG: {svg_file}\n")
            return
        }
        let root = doc.document_element
        // all groups are in <defs>
        for (defs_node in each_child(root, "defs")) {
            // pass 1: collect components recursively (groups without <use> children)
            collect_components_recursive(defs_node, deck, float4(0.0, 0.0, 0.0, 1.0))
            // pass 2: build cards (groups with <use> children)
            for (g in each_child(defs_node, "g")) {
                let id = clone_string(node_attr(g, "id", ""))
                if (length(id) > 0 && has_use_child(g)) {
                    var card_mesh = build_card_mesh(g, deck, Xform2D(), defs_node)
                    if (length(card_mesh.meshes) > 0 || length(card_mesh.stencil_groups) > 0) {
                        deck.cards[id] <- card_mesh
                    }
                }
            }
        }
    }
}

def collect_paths(node : auto; var comp : SvgComponent; parent_fill : float4; parent_xform : Xform2D = Xform2D()) {
    // Iterate ALL children in DOM order to preserve SVG paint order
    for (child in each_child(node)) {
        let tag = child.name
        if (tag == "path") {
            let d = node_attr(child, "d", "")
            if (length(d) > 0) {
                var sp = SvgShapePath()
                sp.d = clone_string(d)
                let style = node_attr(child, "style", "")
                let fill_attr = node_attr(child, "fill", "")
                sp.has_explicit_fill = (length(style) > 0 && find(style, "fill:") >= 0) || length(fill_attr) > 0
                sp.fill = get_fill_color(child, parent_fill)
                if (find(style, "fill-rule:evenodd") >= 0) {
                    sp.evenodd = true
                }
                let path_xform_str = node_attr(child, "transform", "")
                if (length(path_xform_str) > 0) {
                    sp.xform = xform_compose(parent_xform, parse_transform(path_xform_str))
                } else {
                    sp.xform = parent_xform
                }
                comp.paths |> emplace(sp)
            }
        } elif (tag == "g") {
            let fill = get_fill_color(child, parent_fill)
            let g_xform_str = node_attr(child, "transform", "")
            let g_xform = length(g_xform_str) > 0 ? xform_compose(parent_xform, parse_transform(g_xform_str)) : parent_xform
            collect_paths(child, comp, fill, g_xform)
        }
    }
}

// ============================================================================
// Card building
// ============================================================================

def merge_sub_mesh(var result : CardMesh; var sub : CardMesh) {
    for (op in sub.draw_order) {
        if (op.mesh_idx >= 0) {
            let m & = unsafe(sub.meshes[op.mesh_idx])
            var cm : ColoredMesh
            cm.color = m.color
            cm.vertices := m.vertices
            cm.indices := m.indices
            add_mesh(result, cm)
        } elif (op.stencil_idx >= 0) {
            let sg & = unsafe(sub.stencil_groups[op.stencil_idx])
            var sg_copy = StencilGroup()
            sg_copy.color = sg.color
            sg_copy.min_pt = sg.min_pt
            sg_copy.max_pt = sg.max_pt
            sg_copy.evenodd = sg.evenodd
            for (c in sg.contours) {
                var cm : ColoredMesh
                cm.color = c.color
                cm.vertices := c.vertices
                cm.indices := c.indices
                sg_copy.contours |> emplace(cm)
            }
            add_stencil_group(result, sg_copy)
        }
    }
}

def resolve_use(use_node : auto; deck : CardDeck; grp_xform : Xform2D; defs_node : auto; var result : CardMesh) {
    var href = node_attr(use_node, "xlink:href", "")
    if (length(href) == 0) {
        href = node_attr(use_node, "href", "")
    }
    if (length(href) == 0 || character_at(href, 0) != '#') {
        return
    }
    let comp_id = slice(href, 1)
    let style = node_attr(use_node, "style", "")
    // SVG <use> x,y create an additional translate(x,y) applied after the transform
    let use_x = to_float(node_attr(use_node, "x", "0"))
    let use_y = to_float(node_attr(use_node, "y", "0"))
    let xy_translate = xform_translate(use_x, use_y)
    let use_xform_str = node_attr(use_node, "transform", "")
    var use_local = Xform2D()
    if (length(use_xform_str) > 0) {
        use_local = xform_compose(parse_transform(use_xform_str), xy_translate)
    } else {
        use_local = xy_translate
    }
    let use_xform = xform_compose(grp_xform, use_local)
    var fill = float4(0.0, 0.0, 0.0, 1.0)
    if (length(style) > 0 && find(style, "fill:") >= 0) {
        fill = extract_fill_from_style(style)
    }
    var resolved = false
    deck.components |> get(comp_id) <| $(comp) {
        resolved = true
        for (sp in comp.paths) {
            var path_fill = sp.fill
            if (fill.w > 0.0 && !sp.has_explicit_fill) {
                path_fill = fill
            }
            if (path_fill.w <= 0.0) {
                path_fill = fill
            }
            let final_xform = xform_compose(use_xform, sp.xform)
            tessellate_path_xform(sp.d, path_fill, final_xform, result, sp.evenodd)
        }
    }
    // Fallback: search XML tree via XPath for any element with matching id
    if (!resolved) {
        let xpath = "//*[@id='{comp_id}']"
        let found = select_node(defs_node, xpath)
        if (found.ok && found.node.ok) {
            let tag = found.node.name
            if (tag == "path") {
                let d = node_attr(found.node, "d", "")
                if (length(d) > 0) {
                    let path_fill = get_fill_color(found.node, fill)
                    let sty = node_attr(found.node, "style", "")
                    let eo = find(sty, "fill-rule:evenodd") >= 0
                    tessellate_path_xform(d, path_fill, use_xform, result, eo)
                }
            } else {
                var sub = build_card_mesh(found.node, deck, use_xform, defs_node)
                merge_sub_mesh(result, sub)
            }
        }
    }
}

def build_card_mesh(card_node : auto; deck : CardDeck; parent_xform : Xform2D; defs_node : auto) : CardMesh {
    var result : CardMesh
    let grp_xform_str = node_attr(card_node, "transform", "")
    let grp_xform = length(grp_xform_str) > 0 ? xform_compose(parent_xform, parse_transform(grp_xform_str)) : parent_xform
    // Iterate ALL children in DOM order to preserve SVG paint order
    for (child in each_child(card_node)) {
        let tag = child.name
        if (tag == "path") {
            let d = node_attr(child, "d", "")
            if (length(d) > 0) {
                let fill = get_fill_color(child, float4(0.0, 0.0, 0.0, 1.0))
                let style = node_attr(child, "style", "")
                let eo = find(style, "fill-rule:evenodd") >= 0
                tessellate_path_xform(d, fill, grp_xform, result, eo)
            }
        } elif (tag == "rect") {
            let fill = get_fill_color(child, float4(1.0, 1.0, 1.0, 1.0))
            if (fill.w <= 0.0) {
                continue
            }
            let rx = to_float(node_attr(child, "x", "0"))
            let ry = to_float(node_attr(child, "y", "0"))
            let rw = to_float(node_attr(child, "width", "0"))
            let rh = to_float(node_attr(child, "height", "0"))
            if (rw > 0.0 && rh > 0.0) {
                // Apply rect-level transform if present
                var rect_xform = grp_xform
                let rect_xform_str = node_attr(child, "transform", "")
                if (length(rect_xform_str) > 0) {
                    rect_xform = xform_compose(grp_xform, parse_transform(rect_xform_str))
                }
                var cm : ColoredMesh
                cm.color = fill
                cm.vertices |> push(xform_point(float2(rx, ry), rect_xform))
                cm.vertices |> push(xform_point(float2(rx + rw, ry), rect_xform))
                cm.vertices |> push(xform_point(float2(rx + rw, ry + rh), rect_xform))
                cm.vertices |> push(xform_point(float2(rx, ry + rh), rect_xform))
                cm.indices |> push(0); cm.indices |> push(1); cm.indices |> push(2)
                cm.indices |> push(0); cm.indices |> push(2); cm.indices |> push(3)
                add_mesh(result, cm)
            }
        } elif (tag == "use") {
            resolve_use(child, deck, grp_xform, defs_node, result)
        } elif (tag == "g") {
            var sub = build_card_mesh(child, deck, grp_xform, defs_node)
            merge_sub_mesh(result, sub)
        }
    }
    return <- result
}

// ============================================================================
// Tessellation
// ============================================================================

def tessellate_path(d : string; fill : float4; var result : CardMesh) {
    tessellate_path_xform(d, fill, Xform2D(), result)
}

def point_in_polygon(pt : float2; poly : array<float2>) : bool {
    var inside = false
    let n = length(poly)
    var j = n - 1
    for (i in range(n)) {
        let pi = poly[i]
        let pj = poly[j]
        if ((pi.y > pt.y) != (pj.y > pt.y) && pt.x < (pj.x - pi.x) * (pt.y - pi.y) / (pj.y - pi.y) + pi.x) {
            inside = !inside
        }
        j = i
    }
    return inside
}

def signed_polygon_area(pts : array<float2>) : float {
    var area = 0.0
    let n = length(pts)
    for (i in range(n)) {
        let j = (i + 1) % n
        area += pts[i].x * pts[j].y
        area -= pts[j].x * pts[i].y
    }
    return area * 0.5
}

def tessellate_path_xform(d : string; fill : float4; xform : Xform2D; var result : CardMesh; evenodd : bool = false) {
    if (fill.w <= 0.0) {
        return
    }
    let parsed = parse_svg_path(d)
    let flat = flatten_svg_path(parsed, 0.5)
    let num_contours = length(flat.contours)
    if (num_contours == 0) {
        return
    }
    // Transform all contour points, compute centroids and signed areas
    var contours : array<array<float2>>
    var centroids : array<float2>
    var areas : array<float>
    for (i in range(num_contours)) {
        var pts : array<float2>
        if (length(flat.contours[i].points) < 3) {
            contours |> emplace(pts)
            centroids |> push(float2(0.0, 0.0))
            areas |> push(0.0)
            continue
        }
        var c = float2(0.0, 0.0)
        for (pt in flat.contours[i].points) {
            let xpt = xform_point(pt, xform)
            pts |> push(xpt)
            c += xpt
        }
        c /= float(length(pts))
        centroids |> push(c)
        areas |> push(signed_polygon_area(pts))
        contours |> emplace(pts)
    }
    // Single contour — simple case
    if (num_contours == 1) {
        if (length(contours[0]) < 3) {
            return
        }
        var tris = earcut(contours[0])
        if (length(tris) > 0) {
            var cm : ColoredMesh
            cm.color = fill
            cm.vertices <- contours[0]
            cm.indices <- tris
            add_mesh(result, cm)
        }
        return
    }
    // Many contours — use stencil-based rendering for correct fill-rule
    // Triangle fans preserve winding direction, enabling nonzero fill via stencil
    if (num_contours > 1) {
        var sg = StencilGroup(color = fill, evenodd = evenodd,
            min_pt = float2(1e9, 1e9), max_pt = float2(-1e9, -1e9))
        for (i in range(num_contours)) {
            let n = length(contours[i])
            if (n < 3) {
                continue
            }
            for (pt in contours[i]) {
                sg.min_pt = float2(min(sg.min_pt.x, pt.x), min(sg.min_pt.y, pt.y))
                sg.max_pt = float2(max(sg.max_pt.x, pt.x), max(sg.max_pt.y, pt.y))
            }
            // Triangle fan from first vertex — preserves contour winding direction
            var cm : ColoredMesh
            cm.color = fill
            cm.vertices := contours[i]
            for (j in range(1, n - 1)) {
                cm.indices |> push(0)
                cm.indices |> push(j)
                cm.indices |> push(j + 1)
            }
            sg.contours |> emplace(cm)
        }
        if (length(sg.contours) > 0) {
            add_stencil_group(result, sg)
        }
        return
    }
    // Build containment tree: parent[i] = index of smallest contour containing i, or -1
    var par : array<int>
    resize(par, num_contours)
    for (i in range(num_contours)) {
        par[i] = -1
    }
    for (i in range(num_contours)) {
        if (length(contours[i]) < 3) {
            continue
        }
        var best_parent = -1
        var best_area = 1e30
        for (j in range(num_contours)) {
            if (i == j || length(contours[j]) < 3) {
                continue
            }
            if (abs(areas[j]) <= abs(areas[i])) {
                continue  // can't contain us
            }
            if (point_in_polygon(centroids[i], contours[j])) {
                if (abs(areas[j]) < best_area) {
                    best_area = abs(areas[j])
                    best_parent = j
                }
            }
        }
        par[i] = best_parent
    }
    // Compute nesting depth
    var depth : array<int>
    resize(depth, num_contours)
    for (i in range(num_contours)) {
        var dp = 0
        var p = par[i]
        while (p >= 0) {
            dp++
            p = par[p]
        }
        depth[i] = dp
    }
    // Tessellate: even-depth contours are "outers" (filled shapes)
    // Their direct odd-depth children are potential holes
    for (i in range(num_contours)) {
        if (length(contours[i]) < 3) {
            continue
        }
        if ((depth[i] % 2) != 0) {
            continue  // odd depth = hole, handled by parent
        }
        // Collect direct children that are holes
        var poly : array<float2>
        var hole_indices : array<int>
        for (pt in contours[i]) {
            poly |> push(pt)
        }
        let outer_ccw = areas[i] > 0.0
        for (j in range(num_contours)) {
            if (par[j] != i || length(contours[j]) < 3) {
                continue
            }
            if ((depth[j] % 2) != 1) {
                continue
            }
            // For nonzero fill: only opposite winding is a hole
            if (!evenodd) {
                let inner_ccw = areas[j] > 0.0
                if (inner_ccw == outer_ccw) {
                    continue  // same winding = filled, not a hole; will be its own outer at depth+1 effectively
                }
            }
            hole_indices |> push(length(poly))
            for (pt in contours[j]) {
                poly |> push(pt)
            }
        }
        if (length(hole_indices) > 0) {
            var ok = true
            try {
                var tris = earcut(poly, hole_indices)
                if (length(tris) > 0) {
                    var cm : ColoredMesh
                    cm.color = fill
                    cm.vertices <- poly
                    cm.indices <- tris
                    add_mesh(result, cm)
                }
            } recover {
                ok = false
            }
            if (!ok) {
                // Fallback: tessellate outer without holes
                var outer_only : array<float2>
                for (pt in contours[i]) {
                    outer_only |> push(pt)
                }
                var tris = earcut(outer_only)
                if (length(tris) > 0) {
                    var cm : ColoredMesh
                    cm.color = fill
                    cm.vertices <- outer_only
                    cm.indices <- tris
                    add_mesh(result, cm)
                }
            }
        } else {
            var tris = earcut(poly)
            if (length(tris) > 0) {
                var cm : ColoredMesh
                cm.color = fill
                cm.vertices <- poly
                cm.indices <- tris
                add_mesh(result, cm)
            }
        }
    }
    // Handle nonzero same-winding children at odd depth (they're filled, not holes)
    // These need to be tessellated as independent outers
    if (!evenodd) {
        for (j in range(num_contours)) {
            if (length(contours[j]) < 3 || (depth[j] % 2) != 1) {
                continue
            }
            let parent_idx = par[j]
            if (parent_idx < 0) {
                continue
            }
            let parent_ccw = areas[parent_idx] > 0.0
            let child_ccw = areas[j] > 0.0
            if (child_ccw == parent_ccw) {
                // Same winding as parent → filled shape, not a hole
                // Tessellate independently (its own children will be handled separately)
                var poly : array<float2>
                var hole_indices : array<int>
                for (pt in contours[j]) {
                    poly |> push(pt)
                }
                // Collect its direct children as holes
                for (k in range(num_contours)) {
                    if (par[k] != j || length(contours[k]) < 3) {
                        continue
                    }
                    let k_ccw = areas[k] > 0.0
                    if (k_ccw != child_ccw) {
                        hole_indices |> push(length(poly))
                        for (pt in contours[k]) {
                            poly |> push(pt)
                        }
                    }
                }
                if (length(hole_indices) > 0) {
                    var ok = true
                    try {
                        var tris = earcut(poly, hole_indices)
                        if (length(tris) > 0) {
                            var cm : ColoredMesh
                            cm.color = fill
                            cm.vertices <- poly
                            cm.indices <- tris
                            add_mesh(result, cm)
                        }
                    } recover {
                        ok = false
                    }
                    if (!ok) {
                        var outer_only : array<float2>
                        for (pt in contours[j]) {
                            outer_only |> push(pt)
                        }
                        var tris = earcut(outer_only)
                        if (length(tris) > 0) {
                            var cm : ColoredMesh
                            cm.color = fill
                            cm.vertices <- outer_only
                            cm.indices <- tris
                            add_mesh(result, cm)
                        }
                    }
                } else {
                    var tris = earcut(poly)
                    if (length(tris) > 0) {
                        var cm : ColoredMesh
                        cm.color = fill
                        cm.vertices <- poly
                        cm.indices <- tris
                        add_mesh(result, cm)
                    }
                }
            }
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

def load_deck(svg_file : string) : CardDeck {
    var deck : CardDeck
    load_svg_components(svg_file, deck)
    print("Loaded {length(deck.components)} components, {length(deck.cards)} cards\n")
    return <- deck
}
