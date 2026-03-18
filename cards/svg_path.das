options gen2
options no_aot

require math
require strings

// SVG path command types
enum SvgCmd : uint8 {
    MoveTo
    LineTo
    HLineTo
    VLineTo
    CubicTo
    SmoothCubicTo
    ArcTo
    ClosePath
}

struct PathCmd {
    cmd : SvgCmd
    abs : bool
    pts : array<float2>
}

struct ArcParams {
    rx : float
    ry : float
    rotation : float
    large_arc : bool
    sweep : bool
    target : float2
}

struct SvgPath {
    commands : array<PathCmd>
}

// ============================================================================
// SVG path d-attribute parser (pointer-based, O(n))
// ============================================================================

struct PathParser {
    src : string
    dat : uint8?
    pos : int
    len : int
}

def make_parser(d : string) : PathParser {
    return PathParser(src = d, dat = unsafe(reinterpret<uint8?> d), pos = 0, len = length(d))
}

def ch_at(p : PathParser) : int {
    return p.pos < p.len ? int(unsafe(p.dat[p.pos])) : 0
}

def skip_wsc(var p : PathParser) {
    while (p.pos < p.len) {
        let ch = ch_at(p)
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',') {
            p.pos++
        } else {
            break
        }
    }
}

def is_num_start(ch : int) : bool {
    return ch == '-' || ch == '+' || ch == '.' || (ch >= '0' && ch <= '9')
}

def parse_number(var p : PathParser) : float {
    skip_wsc(p)
    let start = p.pos
    if (p.pos < p.len) {
        let ch = ch_at(p)
        if (ch == '-' || ch == '+') {
            p.pos++
        }
    }
    var has_dot = false
    while (p.pos < p.len) {
        let ch = ch_at(p)
        if (ch >= '0' && ch <= '9') {
            p.pos++
        } elif (ch == '.' && !has_dot) {
            has_dot = true
            p.pos++
        } else {
            break
        }
    }
    if (p.pos < p.len) {
        let ch = ch_at(p)
        if (ch == 'e' || ch == 'E') {
            p.pos++
            if (p.pos < p.len) {
                let ch2 = ch_at(p)
                if (ch2 == '-' || ch2 == '+') {
                    p.pos++
                }
            }
            while (p.pos < p.len && ch_at(p) >= '0' && ch_at(p) <= '9') {
                p.pos++
            }
        }
    }
    return float(to_double(slice(p.src, start, p.pos)))
}

def parse_flag(var p : PathParser) : bool {
    skip_wsc(p)
    let ch = ch_at(p)
    p.pos++
    return ch == '1'
}

def parse_coord_pair(var p : PathParser) : float2 {
    let x = parse_number(p)
    let y = parse_number(p)
    return float2(x, y)
}

def has_more_numbers(p : PathParser) : bool {
    var i = p.pos
    while (i < p.len) {
        let ch = int(unsafe(p.dat[i]))
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',') {
            i++
        } elif (is_num_start(ch)) {
            return true
        } else {
            return false
        }
    }
    return false
}

def parse_svg_path(d : string) : SvgPath {
    var result : SvgPath
    var p = make_parser(d)
    while (p.pos < p.len) {
        skip_wsc(p)
        if (p.pos >= p.len) {
            break
        }
        let ch = ch_at(p)
        var is_cmd = false
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
            if (ch != 'e' && ch != 'E') {
                is_cmd = true
                p.pos++
            }
        }
        if (!is_cmd) {
            break
        }
        let is_abs = ch >= 'A' && ch <= 'Z'
        let upper = is_abs ? ch : ch - 'a' + 'A'
        if (upper == 'M') {
            var first = true
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.abs = is_abs
                if (first) {
                    c.cmd = SvgCmd.MoveTo
                    first = false
                } else {
                    c.cmd = SvgCmd.LineTo
                }
                c.pts |> push(parse_coord_pair(p))
                result.commands |> emplace(c)
            }
        } elif (upper == 'L') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.LineTo
                c.abs = is_abs
                c.pts |> push(parse_coord_pair(p))
                result.commands |> emplace(c)
            }
        } elif (upper == 'H') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.HLineTo
                c.abs = is_abs
                c.pts |> push(float2(parse_number(p), 0.0))
                result.commands |> emplace(c)
            }
        } elif (upper == 'V') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.VLineTo
                c.abs = is_abs
                c.pts |> push(float2(0.0, parse_number(p)))
                result.commands |> emplace(c)
            }
        } elif (upper == 'C') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.CubicTo
                c.abs = is_abs
                c.pts |> push(parse_coord_pair(p))
                c.pts |> push(parse_coord_pair(p))
                c.pts |> push(parse_coord_pair(p))
                result.commands |> emplace(c)
            }
        } elif (upper == 'S') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.SmoothCubicTo
                c.abs = is_abs
                c.pts |> push(parse_coord_pair(p))
                c.pts |> push(parse_coord_pair(p))
                result.commands |> emplace(c)
            }
        } elif (upper == 'A') {
            while (has_more_numbers(p)) {
                var c : PathCmd
                c.cmd = SvgCmd.ArcTo
                c.abs = is_abs
                let rx = parse_number(p)
                let ry = parse_number(p)
                let rot = parse_number(p)
                let la = parse_flag(p)
                let sw = parse_flag(p)
                let target = parse_coord_pair(p)
                c.pts |> push(float2(rx, ry))
                c.pts |> push(float2(rot, (la ? 2.0 : 0.0) + (sw ? 1.0 : 0.0)))
                c.pts |> push(target)
                result.commands |> emplace(c)
            }
        } elif (upper == 'Z') {
            var c : PathCmd
            c.cmd = SvgCmd.ClosePath
            c.abs = true
            result.commands |> emplace(c)
        }
    }
    return <- result
}

def unpack_arc(c : PathCmd) : ArcParams {
    return ArcParams(
        rx = c.pts[0].x,
        ry = c.pts[0].y,
        rotation = c.pts[1].x,
        large_arc = c.pts[1].y >= 2.0,
        sweep = (int(c.pts[1].y) & 1) != 0,
        target = c.pts[2]
    )
}

// ============================================================================
// Flatten paths to polylines (resolve relative coords, flatten curves)
// ============================================================================

struct Contour {
    points : array<float2>
    closed : bool
}

struct FlatPath {
    contours : array<Contour>
}

def flatten_cubic(p0, p1, p2, p3 : float2; tolerance : float; var output : array<float2>) {
    let d1 = point_line_distance(p1, p0, p3)
    let d2 = point_line_distance(p2, p0, p3)
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
    flatten_cubic(p0, p01, p012, p0123, tolerance, output)
    flatten_cubic(p0123, p123, p23, p3, tolerance, output)
}

def point_line_distance(p, a, b : float2) : float {
    let ab = b - a
    let len_sq = dot(ab, ab)
    if (len_sq < 1e-12) {
        return length(p - a)
    }
    return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / sqrt(len_sq)
}

def arc_to_cubics(rx0, ry0, x_rot_deg : float; large_arc, sweep : bool; from, to : float2; var output : array<float2>; tolerance : float) {
    if (length(to - from) < 1e-6) {
        return
    }
    var rx = abs(rx0)
    var ry = abs(ry0)
    if (rx < 1e-6 || ry < 1e-6) {
        output |> push(to)
        return
    }
    let phi = x_rot_deg * PI / 180.0
    let cos_phi = cos(phi)
    let sin_phi = sin(phi)
    let dx2 = (from.x - to.x) * 0.5
    let dy2 = (from.y - to.y) * 0.5
    let x1p = cos_phi * dx2 + sin_phi * dy2
    let y1p = -sin_phi * dx2 + cos_phi * dy2
    let x1p_sq = x1p * x1p
    let y1p_sq = y1p * y1p
    var rx_sq = rx * rx
    var ry_sq = ry * ry
    let lam = x1p_sq / rx_sq + y1p_sq / ry_sq
    if (lam > 1.0) {
        let lsq = sqrt(lam)
        rx *= lsq
        ry *= lsq
        rx_sq = rx * rx
        ry_sq = ry * ry
    }
    let num = max(rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq, 0.0)
    let den = rx_sq * y1p_sq + ry_sq * x1p_sq
    var sq = 0.0
    if (den > 1e-12) {
        sq = sqrt(num / den)
    }
    if (large_arc == sweep) {
        sq = -sq
    }
    let cxp = sq * rx * y1p / ry
    let cyp = -sq * ry * x1p / rx
    let cx = cos_phi * cxp - sin_phi * cyp + (from.x + to.x) * 0.5
    let cy = sin_phi * cxp + cos_phi * cyp + (from.y + to.y) * 0.5
    let theta1 = angle_between(float2(1.0, 0.0), float2((x1p - cxp) / rx, (y1p - cyp) / ry))
    var dtheta = angle_between(float2((x1p - cxp) / rx, (y1p - cyp) / ry), float2((-x1p - cxp) / rx, (-y1p - cyp) / ry))
    if (!sweep && dtheta > 0.0) {
        dtheta -= 2.0 * PI
    } elif (sweep && dtheta < 0.0) {
        dtheta += 2.0 * PI
    }
    let n_segs = int(ceil(abs(dtheta) / (PI * 0.5)))
    let seg_angle = dtheta / float(n_segs)
    let alpha = sin(seg_angle) * (sqrt(4.0 + 3.0 * tan(seg_angle * 0.5) * tan(seg_angle * 0.5)) - 1.0) / 3.0
    var prev_x = cos(theta1)
    var prev_y = sin(theta1)
    for (i in range(n_segs)) {
        let angle = theta1 + float(i + 1) * seg_angle
        let cur_x = cos(angle)
        let cur_y = sin(angle)
        let cp1x = prev_x - alpha * prev_y
        let cp1y = prev_y + alpha * prev_x
        let cp2x = cur_x + alpha * cur_y
        let cp2y = cur_y - alpha * cur_x
        let p1 = arc_pt(cp1x, cp1y, rx, ry, cos_phi, sin_phi, cx, cy)
        let p2 = arc_pt(cp2x, cp2y, rx, ry, cos_phi, sin_phi, cx, cy)
        let p3 = arc_pt(cur_x, cur_y, rx, ry, cos_phi, sin_phi, cx, cy)
        let prev_pt = arc_pt(prev_x, prev_y, rx, ry, cos_phi, sin_phi, cx, cy)
        flatten_cubic(prev_pt, p1, p2, p3, tolerance, output)
        prev_x = cur_x
        prev_y = cur_y
    }
}

def arc_pt(x, y, rx, ry, cos_phi, sin_phi, cx, cy : float) : float2 {
    let px = rx * x
    let py = ry * y
    return float2(cos_phi * px - sin_phi * py + cx, sin_phi * px + cos_phi * py + cy)
}

def angle_between(u, v : float2) : float {
    let dot_val = clamp(dot(normalize(u), normalize(v)), -1.0, 1.0)
    var angle = acos(dot_val)
    if (u.x * v.y - u.y * v.x < 0.0) {
        angle = -angle
    }
    return angle
}

// Main flattening function: SvgPath → FlatPath (array of polyline contours)
def flatten_svg_path(path : SvgPath; tolerance : float = 0.5) : FlatPath {
    var result : FlatPath
    var cur = float2(0.0)
    var start = float2(0.0)
    var last_cp = float2(0.0)
    var last_was_cubic = false
    var contour : Contour
    for (cmd in path.commands) {
        if (cmd.cmd == SvgCmd.MoveTo) {
            if (length(contour.points) > 0) {
                result.contours |> emplace(contour)
                contour = Contour()
            }
            let pt = cmd.abs ? cmd.pts[0] : cur + cmd.pts[0]
            cur = pt
            start = pt
            contour.points |> push(pt)
            last_was_cubic = false
        } elif (cmd.cmd == SvgCmd.LineTo) {
            let pt = cmd.abs ? cmd.pts[0] : cur + cmd.pts[0]
            cur = pt
            contour.points |> push(pt)
            last_was_cubic = false
        } elif (cmd.cmd == SvgCmd.HLineTo) {
            let x = cmd.abs ? cmd.pts[0].x : cur.x + cmd.pts[0].x
            cur = float2(x, cur.y)
            contour.points |> push(cur)
            last_was_cubic = false
        } elif (cmd.cmd == SvgCmd.VLineTo) {
            let y = cmd.abs ? cmd.pts[0].y : cur.y + cmd.pts[0].y
            cur = float2(cur.x, y)
            contour.points |> push(cur)
            last_was_cubic = false
        } elif (cmd.cmd == SvgCmd.CubicTo) {
            let p1 = cmd.abs ? cmd.pts[0] : cur + cmd.pts[0]
            let p2 = cmd.abs ? cmd.pts[1] : cur + cmd.pts[1]
            let p3 = cmd.abs ? cmd.pts[2] : cur + cmd.pts[2]
            flatten_cubic(cur, p1, p2, p3, tolerance, contour.points)
            last_cp = p2
            cur = p3
            last_was_cubic = true
        } elif (cmd.cmd == SvgCmd.SmoothCubicTo) {
            let p1 = last_was_cubic ? cur + (cur - last_cp) : cur
            let p2 = cmd.abs ? cmd.pts[0] : cur + cmd.pts[0]
            let p3 = cmd.abs ? cmd.pts[1] : cur + cmd.pts[1]
            flatten_cubic(cur, p1, p2, p3, tolerance, contour.points)
            last_cp = p2
            cur = p3
            last_was_cubic = true
        } elif (cmd.cmd == SvgCmd.ArcTo) {
            let arc = unpack_arc(cmd)
            let target = cmd.abs ? arc.target : cur + arc.target
            arc_to_cubics(arc.rx, arc.ry, arc.rotation, arc.large_arc, arc.sweep, cur, target, contour.points, tolerance)
            cur = target
            last_was_cubic = false
        } elif (cmd.cmd == SvgCmd.ClosePath) {
            cur = start
            contour.closed = true
            result.contours |> emplace(contour)
            contour = Contour()
            last_was_cubic = false
        }
    }
    if (length(contour.points) > 0) {
        result.contours |> emplace(contour)
    }
    return <- result
}
