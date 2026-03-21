options gen2
options persistent_heap

module glyph_path public

require math
require stbimage/stbimage_ttf public
require svg_path

// ============================================================================
// Font loading
// ============================================================================

def load_glyph_font(path : string) : Font {
    var font <- load_font(path)
    if (!is_valid(font)) {
        to_log(LOG_ERROR, "glyph_path: failed to load font: {path}\n")
    }
    return <- font
}

// ============================================================================
// Flatten quadratic bezier (TrueType uses quadratics)
// ============================================================================

def private flatten_quadratic(p0, p1, p2 : float2; tolerance : float; var output : array<float2>) {
    let d = point_line_distance_glyph(p1, p0, p2)
    if (d <= tolerance) {
        output |> push(p2)
        return
    }
    let p01 = (p0 + p1) * 0.5
    let p12 = (p1 + p2) * 0.5
    let mid = (p01 + p12) * 0.5
    flatten_quadratic(p0, p01, mid, tolerance, output)
    flatten_quadratic(mid, p12, p2, tolerance, output)
}

def private point_line_distance_glyph(p, a, b : float2) : float {
    let ab = b - a
    let len_sq = dot(ab, ab)
    if (len_sq < 1e-12) {
        return length(p - a)
    }
    return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / sqrt(len_sq)
}

def private flatten_cubic_glyph(p0, p1, p2, p3 : float2; tolerance : float; var output : array<float2>) {
    let d1 = point_line_distance_glyph(p1, p0, p3)
    let d2 = point_line_distance_glyph(p2, p0, p3)
    if (d1 + d2 <= tolerance) {
        output |> push(p3)
        return
    }
    let p01 = (p0 + p1) * 0.5
    let p12 = (p1 + p2) * 0.5
    let p23 = (p2 + p3) * 0.5
    let p012 = (p01 + p12) * 0.5
    let p123 = (p12 + p23) * 0.5
    let p0123 = (p012 + p123) * 0.5
    flatten_cubic_glyph(p0, p01, p012, p0123, tolerance, output)
    flatten_cubic_glyph(p0123, p123, p23, p3, tolerance, output)
}

// ============================================================================
// Convert glyph outline to FlatPath (in font units * scale)
// ============================================================================

def get_glyph_path(font : Font; codepoint : int; scale : float = 1.0) : FlatPath {
    var result : FlatPath
    if (!is_valid(font)) {
        return <- result
    }
    var cur = float2(0.0, 0.0)
    var contour_pts : array<float2>
    var in_contour = false
    let tolerance = 0.5
    font |> codepoint_shape(codepoint) <| $(v) {
        let vt = int(v.vtype)
        if (vt == STBTT_vmove) {
            if (in_contour && length(contour_pts) >= 3) {
                var c = Contour()
                c.closed = true
                c.points <- contour_pts
                result.contours |> emplace(c)
            }
            delete contour_pts
            contour_pts |> push(float2(float(v.x) * scale, float(v.y) * scale))
            cur = float2(float(v.x) * scale, float(v.y) * scale)
            in_contour = true
        } elif (vt == STBTT_vline) {
            let pt = float2(float(v.x) * scale, float(v.y) * scale)
            contour_pts |> push(pt)
            cur = pt
        } elif (vt == STBTT_vcurve) {
            let ctrl = float2(float(v.cx) * scale, float(v.cy) * scale)
            let endp = float2(float(v.x) * scale, float(v.y) * scale)
            flatten_quadratic(cur, ctrl, endp, tolerance, contour_pts)
            cur = endp
        } elif (vt == STBTT_vcubic) {
            let c1 = float2(float(v.cx) * scale, float(v.cy) * scale)
            let c2 = float2(float(v.cx1) * scale, float(v.cy1) * scale)
            let endp = float2(float(v.x) * scale, float(v.y) * scale)
            flatten_cubic_glyph(cur, c1, c2, endp, tolerance, contour_pts)
            cur = endp
        }
    }
    if (in_contour && length(contour_pts) >= 3) {
        var c = Contour()
        c.closed = true
        c.points <- contour_pts
        result.contours |> emplace(c)
    }
    return <- result
}

// ============================================================================
// Font metrics helpers
// ============================================================================

def get_font_scale(font : Font; pixel_height : float) : float {
    if (!is_valid(font)) {
        return 1.0
    }
    return font |> scale_for_pixel_height(pixel_height)
}

def get_font_ascent(font : Font; scale : float) : float {
    if (!is_valid(font)) {
        return 0.0
    }
    let vm = font |> font_vmetrics()
    return float(vm.ascent) * scale
}

def get_codepoint_advance(font : Font; codepoint : int; scale : float) : float {
    if (!is_valid(font)) {
        return 0.0
    }
    let hm = font |> codepoint_hmetrics(codepoint)
    return float(hm.advance_width) * scale
}

def measure_text_width(font : Font; text : string; pixel_height : float = 22.0) : float {
    if (!is_valid(font)) {
        return 0.0
    }
    return font |> measure_text(text, pixel_height)
}
