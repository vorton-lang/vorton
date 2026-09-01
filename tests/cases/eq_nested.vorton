struct Point { x: Int, y: Int }
struct Line { start: Point, end: Point }

fn main() {
    let l1 = Line { start: Point { x: 0, y: 0 }, end: Point { x: 1, y: 1 } }
    let l2 = Line { start: Point { x: 0, y: 0 }, end: Point { x: 1, y: 1 } }
    let l3 = Line { start: Point { x: 0, y: 0 }, end: Point { x: 2, y: 2 } }
    assert(l1 == l2, "nested struct eq")
    assert(l1 != l3, "nested struct ne")

    // Option eq
    let a: Int? = some(42)
    let b: Int? = some(42)
    let c: Int? = none
    assert(a == b, "option some eq")
    assert(a != c, "option some vs none")
    assert(c == c, "option none eq")
    print("eq_nested: all tests passed")
}
