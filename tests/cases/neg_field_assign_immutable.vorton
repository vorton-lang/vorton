// Test: field assignment on immutable variable should error
// expect: E0205

struct Point {
  x: Int,
  y: Int
}

impl Point {
  fn try_mutate(self) {
    self.x = 10
  }
}

fn main() {
  let p = Point { x: 1, y: 2 }
  p.try_mutate()
}
