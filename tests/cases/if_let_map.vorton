fn main() {
  let m = map_from([(1, "one"), (2, "two")])

  if let some(v) = m.get(1) {
    print(v)
  }

  if let some(v) = m.get(99) {
    print("should not print")
  } else {
    print("not found")
  }
}
