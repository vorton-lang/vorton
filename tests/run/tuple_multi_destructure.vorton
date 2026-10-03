// Regression: multiple let destructure in same block must not collide
fn main() {
  let (a, b) = (1, 2)
  let (c, d) = (3, 4)
  let (e, f, g) = (5, 6, 7)
  print(a + c + e)
  print(b + d + f + g)
}
// expect: 9
// expect: 19
