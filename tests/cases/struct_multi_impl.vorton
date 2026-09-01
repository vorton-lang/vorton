// Test: multiple impl blocks for the same struct

struct Point { x: Int, y: Int }

impl Point {
    fn manhattan(self) -> Int {
        self.x + self.y
    }
}

// Second impl block for same struct (geometric methods)
impl Point {
    fn distance_sq(self) -> Int {
        self.x * self.x + self.y * self.y
    }

    fn translate(self, dx: Int, dy: Int) -> Point {
        Point { x: self.x + dx, y: self.y + dy }
    }
}

fn main() {
    let p = Point { x: 3, y: 4 }

    // Methods from first impl
    assert(p.manhattan() == 7, "manhattan distance")

    // Methods from second impl
    assert(p.distance_sq() == 25, "distance squared")

    let q = p.translate(1, 2)
    assert(q.x == 4, "translate x")
    assert(q.y == 6, "translate y")

    // Chain methods from different impl blocks
    assert(p.translate(2, 3).manhattan() == 12, "chain across impl blocks")

    print("struct_multi_impl: all tests passed")
}
