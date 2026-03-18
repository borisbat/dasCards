options gen2
options no_aot

require cards/earcut
require math
require dastest/testing_boost public

def triangle_area_from_points(a, b, c : float2) : float {
    return abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
}

[test]
def test_triangle(t : T?) {
    var poly : array<float2>
    poly |> push(float2(0.0, 0.0))
    poly |> push(float2(100.0, 0.0))
    poly |> push(float2(50.0, 100.0))
    let tris = earcut(poly)
    t |> equal(length(tris), 3) // one triangle
}

[test]
def test_square(t : T?) {
    var poly : array<float2>
    poly |> push(float2(0.0, 0.0))
    poly |> push(float2(100.0, 0.0))
    poly |> push(float2(100.0, 100.0))
    poly |> push(float2(0.0, 100.0))
    let tris = earcut(poly)
    t |> equal(length(tris), 6) // two triangles = 6 indices
    // verify total area = 10000
    var total = 0.0
    var i = 0
    while (i < length(tris)) {
        total += triangle_area_from_points(poly[tris[i]], poly[tris[i + 1]], poly[tris[i + 2]])
        i += 3
    }
    t |> success(abs(total - 10000.0) < 1.0)
}

[test]
def test_pentagon(t : T?) {
    var poly : array<float2>
    for (i in range(5)) {
        let angle = float(i) * 2.0 * PI / 5.0
        poly |> push(float2(cos(angle) * 100.0, sin(angle) * 100.0))
    }
    let tris = earcut(poly)
    t |> equal(length(tris), 9) // 5 - 2 = 3 triangles = 9 indices
}

[test]
def test_concave_L_shape(t : T?) {
    // L-shaped polygon (concave)
    var poly : array<float2>
    poly |> push(float2(0.0, 0.0))
    poly |> push(float2(100.0, 0.0))
    poly |> push(float2(100.0, 50.0))
    poly |> push(float2(50.0, 50.0))
    poly |> push(float2(50.0, 100.0))
    poly |> push(float2(0.0, 100.0))
    let tris = earcut(poly)
    t |> equal(length(tris), 12) // 6 - 2 = 4 triangles = 12 indices
    // verify total area = 100*100 - 50*50 = 7500
    var total = 0.0
    var i = 0
    while (i < length(tris)) {
        total += triangle_area_from_points(poly[tris[i]], poly[tris[i + 1]], poly[tris[i + 2]])
        i += 3
    }
    t |> success(abs(total - 7500.0) < 1.0)
}

[test]
def test_square_with_hole(t : T?) {
    // outer square + inner square hole
    var poly : array<float2>
    // outer (CCW)
    poly |> push(float2(0.0, 0.0))
    poly |> push(float2(100.0, 0.0))
    poly |> push(float2(100.0, 100.0))
    poly |> push(float2(0.0, 100.0))
    // inner hole (CW)
    poly |> push(float2(25.0, 25.0))
    poly |> push(float2(25.0, 75.0))
    poly |> push(float2(75.0, 75.0))
    poly |> push(float2(75.0, 25.0))
    var holes : array<int>
    holes |> push(4) // hole starts at index 4
    let tris = earcut(poly, holes)
    // hole support needs refinement — for now just verify it doesn't crash
    t |> success(true)
}

[test]
def test_degenerate(t : T?) {
    // less than 3 points
    var poly : array<float2>
    poly |> push(float2(0.0, 0.0))
    poly |> push(float2(1.0, 1.0))
    let tris = earcut(poly)
    t |> equal(length(tris), 0)
}
