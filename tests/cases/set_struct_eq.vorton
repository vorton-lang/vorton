// #90: Verify Set.insert/remove use Eq trait consistently with Set.contains

struct Point { x: Int, y: Int }

fn main() {
    // Two Eq-equal structs with different references
    let p1 = Point { x: 1, y: 2 }
    let p2 = Point { x: 1, y: 2 }

    // Insert two Eq-equal structs: set should have only 1 element
    let mut s: Set<Point> = set_new()
    s.insert(p1)
    s.insert(p2)
    assert(s.len() == 1, "set should deduplicate Eq-equal structs on insert")

    // contains should find Eq-equal struct
    let p3 = Point { x: 1, y: 2 }
    assert(s.contains(p3), "contains finds Eq-equal struct")

    // Insert a different struct
    let p4 = Point { x: 3, y: 4 }
    s.insert(p4)
    assert(s.len() == 2, "set should have 2 elements after inserting different struct")

    // Remove using Eq-equal struct (different reference)
    let p5 = Point { x: 1, y: 2 }
    s.remove(p5)
    assert(s.len() == 1, "remove should find and remove Eq-equal struct")
    assert(!s.contains(p5), "removed struct should not be found")
    assert(s.contains(p4), "other struct should still be present")

    print("pass: set struct eq consistency")
}
