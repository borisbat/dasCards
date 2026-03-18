options gen2

module earcut public

require math

// Port of mapbox/earcut (ISC license)
// Polygon triangulation via ear clipping with z-order optimization

struct EarcutNode {
    i : int         // vertex index in flat coords array
    x : float
    y : float
    prev_idx : int  // index in nodes array
    next_idx : int
    z : int         // z-order curve value
    prev_z : int    // index of previous node in z-order
    next_z : int    // index of next node in z-order
    steiner : bool  // is this a steiner point
}

struct Earcut {
    nodes : array<EarcutNode>
    triangles : array<int>
    min_x : float
    min_y : float
    max_x : float
    max_y : float
    inv_size : float
}

def private alloc_node(var ec : Earcut; i : int; x, y : float) : int {
    let idx = length(ec.nodes)
    ec.nodes |> push(EarcutNode(
        i = i, x = x, y = y,
        prev_idx = -1, next_idx = -1,
        z = 0, prev_z = -1, next_z = -1,
        steiner = false
    ))
    return idx
}

def private insert_node(var ec : Earcut; i : int; x, y : float; last : int) : int {
    let p = alloc_node(ec, i, x, y)
    if (last < 0) {
        ec.nodes[p].prev_idx = p
        ec.nodes[p].next_idx = p
    } else {
        ec.nodes[p].next_idx = ec.nodes[last].next_idx
        ec.nodes[p].prev_idx = last
        ec.nodes[ec.nodes[last].next_idx].prev_idx = p
        ec.nodes[last].next_idx = p
    }
    return p
}

def private remove_node(var ec : Earcut; p : int) {
    ec.nodes[ec.nodes[p].prev_idx].next_idx = ec.nodes[p].next_idx
    ec.nodes[ec.nodes[p].next_idx].prev_idx = ec.nodes[p].prev_idx
    if (ec.nodes[p].prev_z >= 0) {
        ec.nodes[ec.nodes[p].prev_z].next_z = ec.nodes[p].next_z
    }
    if (ec.nodes[p].next_z >= 0) {
        ec.nodes[ec.nodes[p].next_z].prev_z = ec.nodes[p].prev_z
    }
}

// create a linked list from polygon vertices in the specified winding order
def private linked_list(var ec : Earcut; points : array<float2>; start, end_idx : int; clockwise : bool) : int {
    var last = -1
    if (clockwise) {
        for (i in range(start, end_idx)) {
            last = insert_node(ec, i, points[i].x, points[i].y, last)
        }
    } else {
        var i = end_idx - 1
        while (i >= start) {
            last = insert_node(ec, i, points[i].x, points[i].y, last)
            i--
        }
    }
    if (last >= 0 && equals(ec, last, ec.nodes[last].next_idx)) {
        remove_node(ec, last)
        last = ec.nodes[last].next_idx
    }
    if (last < 0) {
        return -1
    }
    return ec.nodes[last].next_idx
}

def private equals(ec : Earcut; p1, p2 : int) : bool {
    return ec.nodes[p1].x == ec.nodes[p2].x && ec.nodes[p1].y == ec.nodes[p2].y
}

def private signed_area(points : array<float2>; start, end_idx : int) : float {
    var sum = 0.0
    var j = end_idx - 1
    for (i in range(start, end_idx)) {
        sum += (points[j].x - points[i].x) * (points[i].y + points[j].y)
        j = i
    }
    return sum
}

// main earcut function
def earcut(polygon : array<float2>; hole_indices : array<int>) : array<int> {
    var ec : Earcut
    let n = length(polygon)
    if (n < 3) {
        return <- ec.triangles
    }
    let has_holes = length(hole_indices) > 0
    let outer_len = has_holes ? hole_indices[0] : n
    var outer_node = linked_list(ec, polygon, 0, outer_len, signed_area(polygon, 0, outer_len) > 0.0)
    if (outer_node < 0) {
        return <- ec.triangles
    }
    if (has_holes) {
        outer_node = eliminate_holes(ec, polygon, hole_indices, outer_node)
    }
    // set up bounding box for z-order optimization
    ec.min_x = polygon[0].x
    ec.min_y = polygon[0].y
    ec.max_x = polygon[0].x
    ec.max_y = polygon[0].y
    for (i in range(n)) {
        ec.min_x = min(ec.min_x, polygon[i].x)
        ec.min_y = min(ec.min_y, polygon[i].y)
        ec.max_x = max(ec.max_x, polygon[i].x)
        ec.max_y = max(ec.max_y, polygon[i].y)
    }
    let dx = ec.max_x - ec.min_x
    let dy = ec.max_y - ec.min_y
    let max_dim = max(dx, dy)
    ec.inv_size = max_dim != 0.0 ? (32767.0 / max_dim) : 0.0
    earcut_linked(ec, outer_node, 0)
    return <- ec.triangles
}

// convenience overload without holes
def earcut(polygon : array<float2>) : array<int> {
    var no_holes : array<int>
    return <- earcut(polygon, no_holes)
}

def private earcut_linked(var ec : Earcut; ear_in : int; pass_num : int) {
    if (ear_in < 0) {
        return
    }
    var ear = ear_in
    // on first pass, use z-order optimization
    if (pass_num == 0 && ec.inv_size != 0.0) {
        index_curve(ec, ear)
    }
    var stop = ear
    while (ec.nodes[ear].prev_idx != ec.nodes[ear].next_idx) {
        let prev = ec.nodes[ear].prev_idx
        let next = ec.nodes[ear].next_idx
        if (is_ear_hashed(ec, ear)) {
            ec.triangles |> push(ec.nodes[prev].i)
            ec.triangles |> push(ec.nodes[ear].i)
            ec.triangles |> push(ec.nodes[next].i)
            remove_node(ec, ear)
            ear = ec.nodes[next].next_idx
            stop = ear
            continue
        }
        ear = next
        if (ear == stop) {
            // try filtering or splitting
            if (pass_num == 0) {
                earcut_linked(ec, filter_points(ec, ear, -1), 1)
            } elif (pass_num == 1) {
                let filtered = filter_points(ec, ear, -1)
                earcut_linked(ec, filtered, 2)
            }
            break
        }
    }
}

def private is_ear_hashed(ec : Earcut; ear : int) : bool {
    let a = ec.nodes[ec.nodes[ear].prev_idx]
    let b = ec.nodes[ear]
    let c = ec.nodes[ec.nodes[ear].next_idx]
    if (area(a, b, c) >= 0.0) {
        return false // reflex — not an ear
    }
    // use z-order to check nearby points
    let min_tx = min(a.x, min(b.x, c.x))
    let min_ty = min(a.y, min(b.y, c.y))
    let max_tx = max(a.x, max(b.x, c.x))
    let max_ty = max(a.y, max(b.y, c.y))
    let min_z = z_order(min_tx, min_ty, ec.min_x, ec.min_y, ec.inv_size)
    let max_z = z_order(max_tx, max_ty, ec.min_x, ec.min_y, ec.inv_size)
    var p = b.prev_z
    var n = b.next_z
    while (p >= 0 && ec.nodes[p].z >= min_z && n >= 0 && ec.nodes[n].z <= max_z) {
        if (p >= 0 && ec.nodes[p].z >= min_z) {
            if (p != ec.nodes[ear].prev_idx && p != ec.nodes[ear].next_idx) {
                if (point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, ec.nodes[p].x, ec.nodes[p].y)) {
                    if (area(ec.nodes[ec.nodes[p].prev_idx], ec.nodes[p], ec.nodes[ec.nodes[p].next_idx]) >= 0.0) {
                        return false
                    }
                }
            }
            p = ec.nodes[p].prev_z
        }
        if (n >= 0 && ec.nodes[n].z <= max_z) {
            if (n != ec.nodes[ear].prev_idx && n != ec.nodes[ear].next_idx) {
                if (point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, ec.nodes[n].x, ec.nodes[n].y)) {
                    if (area(ec.nodes[ec.nodes[n].prev_idx], ec.nodes[n], ec.nodes[ec.nodes[n].next_idx]) >= 0.0) {
                        return false
                    }
                }
            }
            n = ec.nodes[n].next_z
        }
    }
    // check remaining on one side
    while (p >= 0 && ec.nodes[p].z >= min_z) {
        if (p != ec.nodes[ear].prev_idx && p != ec.nodes[ear].next_idx) {
            if (point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, ec.nodes[p].x, ec.nodes[p].y)) {
                if (area(ec.nodes[ec.nodes[p].prev_idx], ec.nodes[p], ec.nodes[ec.nodes[p].next_idx]) >= 0.0) {
                    return false
                }
            }
        }
        p = ec.nodes[p].prev_z
    }
    while (n >= 0 && ec.nodes[n].z <= max_z) {
        if (n != ec.nodes[ear].prev_idx && n != ec.nodes[ear].next_idx) {
            if (point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, ec.nodes[n].x, ec.nodes[n].y)) {
                if (area(ec.nodes[ec.nodes[n].prev_idx], ec.nodes[n], ec.nodes[ec.nodes[n].next_idx]) >= 0.0) {
                    return false
                }
            }
        }
        n = ec.nodes[n].next_z
    }
    return true
}

def private filter_points(var ec : Earcut; start_in : int; end_in : int) : int {
    var start = start_in
    if (start < 0) {
        return start
    }
    var end_node = end_in < 0 ? start : end_in
    var p = start
    var again = true
    while (again) {
        again = false
        if (!ec.nodes[p].steiner && (equals(ec, p, ec.nodes[p].next_idx) || area(ec.nodes[ec.nodes[p].prev_idx], ec.nodes[p], ec.nodes[ec.nodes[p].next_idx]) == 0.0)) {
            remove_node(ec, p)
            let next = ec.nodes[p].next_idx
            p = next
            end_node = next
            if (p == next) {
                return -1
            }
            again = true
        } else {
            p = ec.nodes[p].next_idx
            if (p == end_node) {
                again = false
            }
        }
    }
    return end_node
}

def private index_curve(var ec : Earcut; start : int) {
    var p = start
    while (true) {
        ec.nodes[p].z = z_order(ec.nodes[p].x, ec.nodes[p].y, ec.min_x, ec.min_y, ec.inv_size)
        ec.nodes[p].prev_z = ec.nodes[p].prev_idx
        ec.nodes[p].next_z = ec.nodes[p].next_idx
        p = ec.nodes[p].next_idx
        if (p == start) {
            break
        }
    }
    ec.nodes[ec.nodes[start].prev_z].next_z = -1
    ec.nodes[start].prev_z = -1
    sort_linked(ec, start)
}

def private sort_linked(var ec : Earcut; list_in : int) {
    var in_size = 1
    var list = list_in
    while (true) {
        var p = list
        list = -1
        var tail = -1
        var num_merges = 0
        while (p >= 0) {
            num_merges++
            var q = p
            var p_size = 0
            for (_ in range(in_size)) {
                p_size++
                q = ec.nodes[q].next_z
                if (q < 0) {
                    break
                }
            }
            var q_size = in_size
            while (p_size > 0 || (q_size > 0 && q >= 0)) {
                var e : int
                if (p_size != 0 && (q_size == 0 || q < 0 || ec.nodes[p].z <= ec.nodes[q].z)) {
                    e = p
                    p = ec.nodes[p].next_z
                    p_size--
                } else {
                    e = q
                    q = ec.nodes[q].next_z
                    q_size--
                }
                if (tail >= 0) {
                    ec.nodes[tail].next_z = e
                } else {
                    list = e
                }
                ec.nodes[e].prev_z = tail
                tail = e
            }
            p = q
        }
        ec.nodes[tail].next_z = -1
        if (num_merges <= 1) {
            break
        }
        in_size *= 2
    }
}

// z-order of a point given coords and inverse of the bounding box size
def private z_order(x0, y0, min_x, min_y, inv_size : float) : int {
    var x = int((x0 - min_x) * inv_size) & int(0x7FFF)
    var y = int((y0 - min_y) * inv_size) & int(0x7FFF)
    x = (x | (x << 8)) & int(0x00FF00FF)
    x = (x | (x << 4)) & int(0x0F0F0F0F)
    x = (x | (x << 2)) & int(0x33333333)
    x = (x | (x << 1)) & int(0x55555555)
    y = (y | (y << 8)) & int(0x00FF00FF)
    y = (y | (y << 4)) & int(0x0F0F0F0F)
    y = (y | (y << 2)) & int(0x33333333)
    y = (y | (y << 1)) & int(0x55555555)
    return x | (y << 1)
}

def private area(p, q, r : EarcutNode) : float {
    return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
}

def private point_in_triangle(ax, ay, bx, by, cx, cy, px, py : float) : bool {
    let d0 = (cx - px) * (ay - py) - (ax - px) * (cy - py)
    let d1 = (ax - px) * (by - py) - (bx - px) * (ay - py)
    let d2 = (bx - px) * (cy - py) - (cx - px) * (by - py)
    return d0 >= 0.0 && d1 >= 0.0 && d2 >= 0.0
}

// eliminate holes by bridge edges
def private eliminate_holes(var ec : Earcut; points : array<float2>; hole_indices : array<int>; outer_node_in : int) : int {
    var outer_node = outer_node_in
    var queue : array<int>
    let n_holes = length(hole_indices)
    for (i in range(n_holes)) {
        let start = hole_indices[i]
        let end_idx = i < n_holes - 1 ? hole_indices[i + 1] : length(points)
        let list = linked_list(ec, points, start, end_idx, signed_area(points, start, end_idx) < 0.0)
        if (list >= 0) {
            queue |> push(get_leftmost(ec, list))
        }
    }
    // sort holes by x
    sort(queue) <| $(a, b : int) : bool {
        return ec.nodes[a].x < ec.nodes[b].x
    }
    for (q in queue) {
        if (outer_node < 0) {
            break
        }
        outer_node = eliminate_hole(ec, q, outer_node)
    }
    return outer_node
}

def private get_leftmost(ec : Earcut; start : int) : int {
    var p = start
    var leftmost = start
    while (true) {
        if (ec.nodes[p].x < ec.nodes[leftmost].x || (ec.nodes[p].x == ec.nodes[leftmost].x && ec.nodes[p].y < ec.nodes[leftmost].y)) {
            leftmost = p
        }
        p = ec.nodes[p].next_idx
        if (p == start) {
            break
        }
    }
    return leftmost
}

def private eliminate_hole(var ec : Earcut; hole, outer_node : int) : int {
    let bridge = find_hole_bridge(ec, hole, outer_node)
    if (bridge < 0) {
        return outer_node
    }
    let bridge_reverse = split_polygon(ec, bridge, hole)
    filter_points(ec, bridge_reverse, ec.nodes[bridge_reverse].next_idx)
    return filter_points(ec, bridge, ec.nodes[bridge].next_idx)
}

def private find_hole_bridge(ec : Earcut; hole, outer_node : int) : int {
    var p = outer_node
    let hx = ec.nodes[hole].x
    let hy = ec.nodes[hole].y
    var qx = -1e38
    var m = -1
    // find segment that contains hole point horizontally
    while (true) {
        let px = ec.nodes[p].x
        let py = ec.nodes[p].y
        let next = ec.nodes[p].next_idx
        let nx = ec.nodes[next].x
        let ny = ec.nodes[next].y
        if (hy <= max(py, ny) && hy >= min(py, ny) && nx != px) {
            let x = px + (hy - py) * (nx - px) / (ny - py)
            if (x <= hx && x > qx) {
                qx = x
                m = px < nx ? p : next
                if (x == hx) {
                    return m
                }
            }
        }
        p = next
        if (p == outer_node) {
            break
        }
    }
    if (m < 0) {
        return -1
    }
    // look for points inside the triangle to find the closest visible point
    let stop = m
    let mx = ec.nodes[m].x
    let my = ec.nodes[m].y
    var tan_min = 1e38
    p = m
    while (true) {
        let px = ec.nodes[p].x
        let py = ec.nodes[p].y
        if (hx >= px && px >= mx && hx != px) {
            if (point_in_triangle(hy < my ? hx : qx, hy, mx, my, hy >= my ? hx : qx, hy, px, py)) {
                let t = abs(hy - py) / (hx - px)
                if (locally_inside(ec, p, hole) && (t < tan_min || (t == tan_min && (px > ec.nodes[m].x || sector_contains_sector(ec, m, p))))) {
                    m = p
                    tan_min = t
                }
            }
        }
        p = ec.nodes[p].next_idx
        if (p == stop) {
            break
        }
    }
    return m
}

def private locally_inside(ec : Earcut; a, b : int) : bool {
    if (area(ec.nodes[ec.nodes[a].prev_idx], ec.nodes[a], ec.nodes[ec.nodes[a].next_idx]) < 0.0) {
        return area(ec.nodes[a], ec.nodes[b], ec.nodes[ec.nodes[a].next_idx]) >= 0.0 && area(ec.nodes[a], ec.nodes[ec.nodes[a].prev_idx], ec.nodes[b]) >= 0.0
    } else {
        return area(ec.nodes[a], ec.nodes[b], ec.nodes[ec.nodes[a].prev_idx]) < 0.0 || area(ec.nodes[a], ec.nodes[ec.nodes[a].next_idx], ec.nodes[b]) < 0.0
    }
}

def private sector_contains_sector(ec : Earcut; m, p : int) : bool {
    return area(ec.nodes[ec.nodes[m].prev_idx], ec.nodes[m], ec.nodes[ec.nodes[p].prev_idx]) < 0.0 && area(ec.nodes[ec.nodes[p].next_idx], ec.nodes[m], ec.nodes[ec.nodes[m].next_idx]) < 0.0
}

def private split_polygon(var ec : Earcut; a, b : int) : int {
    let a2 = alloc_node(ec, ec.nodes[a].i, ec.nodes[a].x, ec.nodes[a].y)
    let b2 = alloc_node(ec, ec.nodes[b].i, ec.nodes[b].x, ec.nodes[b].y)
    let an = ec.nodes[a].next_idx
    let bp = ec.nodes[b].prev_idx
    ec.nodes[a].next_idx = b
    ec.nodes[b].prev_idx = a
    ec.nodes[a2].next_idx = an
    ec.nodes[an].prev_idx = a2
    ec.nodes[b2].next_idx = a2
    ec.nodes[a2].prev_idx = b2
    ec.nodes[bp].next_idx = b2
    ec.nodes[b2].prev_idx = bp
    return b2
}
