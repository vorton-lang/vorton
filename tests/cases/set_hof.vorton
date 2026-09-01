fn main() {
  let s = set_from([1, 2, 3, 4, 5])

  let evens = s.filter(fn(x: Int) -> Bool { x % 2 == 0 })
  print(evens.len())

  let sum = s.fold(0, fn(acc: Int, x: Int) -> Int { acc + x })
  print(sum)

  let has_big = s.any(fn(x: Int) -> Bool { x > 4 })
  print(has_big)

  let all_pos = s.all(fn(x: Int) -> Bool { x > 0 })
  print(all_pos)
}
