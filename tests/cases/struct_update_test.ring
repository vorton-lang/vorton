// Struct update syntax: { ..base, field: new_val }

struct Point { x: Int, y: Int }

struct Config {
  name: Str,
  width: Int,
  height: Int,
}

// Basic struct update — override one field
fn move_x(p: Point, dx: Int) -> Point {
  Point { ..p, x: p.x + dx }
}

// Override multiple fields
fn resize(c: Config, w: Int, h: Int) -> Config {
  Config { ..c, width: w, height: h }
}

// Clone with no overrides
fn clone_point(p: Point) -> Point {
  Point { ..p }
}

// Spread from a complex expression (function call)
fn make_point(x: Int, y: Int) -> Point {
  Point { x, y }
}

fn shift_new() -> Point {
  Point { ..make_point(1, 2), x: 100 }
}

// Nested structs
struct Rect { origin: Point, size: Point }

fn move_rect(r: Rect, dx: Int) -> Rect {
  // MOVE SPREAD rejects consuming a child place out of an owning aggregate.
  // Rebuild the child from reads, then consume the whole Rect once.
  let new_origin = Point { x: r.origin.x + dx, y: r.origin.y }
  Rect { ..r, origin: new_origin }
}

fn main() {
  let p = Point { x: 1, y: 2 }
  let q = move_x(p, 10)
  assert(q.x == 11, "q.x should be 11")
  assert(q.y == 2, "q.y should be 2")

  let c = Config { name: "test", width: 100, height: 200 }
  let c2 = resize(c, 640, 480)
  assert(c2.name == "test", "name unchanged")
  assert(c2.width == 640, "width updated")
  assert(c2.height == 480, "height updated")

  let p2 = clone_point(p)
  assert(p2.x == 1, "clone x")
  assert(p2.y == 2, "clone y")

  let p3 = shift_new()
  assert(p3.x == 100, "complex spread x")
  assert(p3.y == 2, "complex spread y")

  let r = Rect { origin: Point { x: 0, y: 0 }, size: Point { x: 10, y: 20 } }
  let r2 = move_rect(r, 5)
  assert(r2.origin.x == 5, "rect origin moved")
  assert(r2.origin.y == 0, "rect origin y unchanged")
  assert(r2.size.x == 10, "rect size unchanged")

  print("struct update: all tests passed")
}
