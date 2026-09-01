fn main() {
  let xs = [1, 2, 3, 4, 5]
  let doubled = xs.map(fn(x) { x * 2 })
  print(doubled.len())
  match doubled.first() {
    some(v) => print(v),
    none => print(0),
  }
  let evens = xs.filter(fn(x) { x % 2 == 0 })
  print(evens.len())
  print(xs.any(fn(x) { x > 3 }))
  print(xs.all(fn(x) { x > 0 }))
  match xs.find(fn(x) { x > 3 }) {
    some(v) => print(v),
    none => print(-1),
  }
}
