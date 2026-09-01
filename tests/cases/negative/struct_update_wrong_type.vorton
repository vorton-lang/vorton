// ERROR: struct update with wrong base type

struct Point { x: Int, y: Int }
struct Vec2 { x: Int, y: Int }

fn main() {
  let v = Vec2 { x: 1, y: 2 }
  let p = Point { ..v, x: 10 }  // E0301: Vec2 != Point
  print(p.x)
}
