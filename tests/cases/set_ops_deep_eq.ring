struct Point { x: Int, y: Int }

fn main() with {console} {
    let a = set_from([Point { x: 1, y: 2 }, Point { x: 3, y: 4 }])
    let b = set_from([Point { x: 3, y: 4 }, Point { x: 5, y: 6 }])

    let u = a.union(b)
    assert(u.len() == 3, "union should deduplicate by structural equality")

    let i = a.intersect(b)
    assert(i.len() == 1, "intersect should find structurally equal elements")
    assert(i.contains(Point { x: 3, y: 4 }), "intersect should contain Point(3,4)")

    let d = a.difference(b)
    assert(d.len() == 1, "difference should exclude structurally equal elements")
    assert(d.contains(Point { x: 1, y: 2 }), "difference should contain Point(1,2)")

    print("Set ops deep equality: all passed")
}
