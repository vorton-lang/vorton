// expect-error: E0301
// Test: method called with too many arguments should be rejected
struct Point { x: Int, y: Int }

impl Point {
    fn sum(self) -> Int { self.x + self.y }
}

fn main() {
    let p = Point { x: 1, y: 2 }
    let _ = p.sum(99)
}
