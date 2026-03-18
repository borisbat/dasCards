options gen2
options persistent_heap

module glyph_path public

require math
require fio
require stbtruetype
require svg_path

// ============================================================================
// Font loading and glyph-to-contour conversion
// ============================================================================

var font_loaded = false
var font_data : array<uint8>
var font_info : stbtt_fontinfo

def private ensure_font_loaded() {
    if (font_loaded) {
        return
    }
    let f = fopen("cards/DejaVuSerif.ttf", "rb")
    if (f != null) {
        let st = fstat(f)
        font_data |> resize(int(st.size))
        fread(f, font_data)
        fclose(f)
    }
    if (length(font_data) == 0) {
        print("glyph_path: failed to load font\n")
        return
    }
    unsafe {
        let ok = stbtt_InitFont(addr(font_info), addr(font_data[0]), 0)
        if (ok != 0) {
            font_loaded = true
            print("glyph_path: font loaded, {font_info.numGlyphs} glyphs\n")
        } else {
            print("glyph_path: stbtt_InitFont failed\n")
        }
    }
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

def get_glyph_path(codepoint : int; scale : float = 1.0) : FlatPath {
    var result : FlatPath
    ensure_font_loaded()
    if (!font_loaded) {
        return <- result
    }
    var cur = float2(0.0, 0.0)
    var contour_pts : array<float2>
    var in_contour = false
    let tolerance = 0.5
    unsafe {
        stbtt_GetCodepointShape(addr(font_info), codepoint) <| $(v) {
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

def get_font_scale(pixel_height : float) : float {
    ensure_font_loaded()
    if (!font_loaded) {
        return 1.0
    }
    unsafe {
        return stbtt_ScaleForPixelHeight(addr(font_info), pixel_height)
    }
    return 1.0
}

def get_font_ascent(scale : float) : float {
    ensure_font_loaded()
    if (!font_loaded) {
        return 0.0
    }
    var ascent = 0
    var descent = 0
    var line_gap = 0
    unsafe {
        stbtt_GetFontVMetrics(addr(font_info), addr(ascent), addr(descent), addr(line_gap))
    }
    return float(ascent) * scale
}

def get_codepoint_advance(codepoint : int; scale : float) : float {
    var advance_w = 0
    var lsb = 0
    unsafe {
        stbtt_GetCodepointHMetrics(addr(font_info), codepoint, addr(advance_w), addr(lsb))
    }
    return float(advance_w) * scale
}

def measure_text_width(text : string; pixel_height : float = 22.0) : float {
    ensure_font_loaded()
    if (!font_loaded) {
        return 0.0
    }
    let scale = get_font_scale(pixel_height)
    var width = 0.0
    for (ch in each(text)) {
        width += get_codepoint_advance(int(ch), scale)
    }
    return width
}
