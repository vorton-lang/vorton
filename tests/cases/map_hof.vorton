fn main() {
  let m = map_from([(1, 10), (2, 20), (3, 30)])

  let doubled = m.map_values(fn(v: Int) -> Int { v * 2 })
  match doubled.get(2) {
    some(v) => print(v),
    none => print("err"),
  }

  let big = m.filter(fn(k: Int, v: Int) -> Bool { v > 15 })
  print(big.len())

  let sum = m.fold(0, fn(acc: Int, k: Int, v: Int) -> Int { acc + v })
  print(sum)

  let has_big = m.any(fn(k: Int, v: Int) -> Bool { v > 25 })
  print(has_big)
}
