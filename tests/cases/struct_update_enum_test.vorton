// Struct update for enum named variants

enum Shape {
  Circle { radius: Int, color: Str },
  Rect { width: Int, height: Int, color: Str },
}

fn recolor(s: Shape, c: Str) -> Shape {
  match s {
    Circle { radius, color } => Circle { ..s, color: c },
    Rect { width, height, color } => Rect { ..s, color: c },
  }
}

fn scale_circle(s: Shape) -> Shape {
  match s {
    Circle { radius, .. } => Circle { ..s, radius: radius * 2 },
    _ => s,
  }
}

fn main() {
  let c = Circle { radius: 10, color: "red" }
  let c2 = recolor(c, "blue")
  match c2 {
    Circle { radius, color } => {
      assert(radius == 10, "radius unchanged")
      assert(color == "blue", "color updated")
    },
    _ => panic("expected Circle"),
  }

  let c3 = scale_circle(c)
  match c3 {
    Circle { radius, color } => {
      assert(radius == 20, "radius doubled")
      assert(color == "red", "color unchanged")
    },
    _ => panic("expected Circle"),
  }

  print("struct update enum: all tests passed")
}
