// Negative test: assigning to a field of a temporary value should be rejected.
// The result of make_point() is a temporary — modifying its field is a no-op
// because the temporary is immediately discarded.

struct Point { x: Int, y: Int }

fn make_point() -> Point {
    Point { x: 0, y: 0 }
}

fn main() {
    make_point().x = 5
}
