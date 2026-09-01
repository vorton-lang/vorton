fn unwrap_nested(x: Option<Int?>) -> Int {
  match x {
    some(some(v)) => v,
    none => 0,
  }
}

fn main() -> Int {
  unwrap_nested(some(some(42)))
}
