// Test: impl methods without trait (UFCS) — multiple methods, method chaining

struct Vec2 { x: Int, y: Int }

impl Vec2 {
    fn add(self, other: Vec2) -> Vec2 {
        Vec2 { x: self.x + other.x, y: self.y + other.y }
    }

    fn scale(self, factor: Int) -> Vec2 {
        Vec2 { x: self.x * factor, y: self.y * factor }
    }

    fn dot(self, other: Vec2) -> Int {
        self.x * other.x + self.y * other.y
    }

    fn magnitude_sq(self) -> Int {
        self.x * self.x + self.y * self.y
    }
}

fn main() {
    let a = Vec2 { x: 1, y: 2 }
    let b = Vec2 { x: 3, y: 4 }

    // Basic method calls
    let c = a.add(b)
    assert(c.x == 4, "add x")
    assert(c.y == 6, "add y")

    // Chained method calls
    let d = a.scale(2).add(b)
    assert(d.x == 5, "chain scale add x")
    assert(d.y == 8, "chain scale add y")

    // Method returning scalar
    assert(a.dot(b) == 11, "dot product")
    assert(a.magnitude_sq() == 5, "magnitude squared")

    // Chain that feeds back into method
    let e = a.add(b).scale(3)
    assert(e.x == 12, "add then scale x")
    assert(e.y == 18, "add then scale y")

    print("trait_impl_method: all tests passed")
}
