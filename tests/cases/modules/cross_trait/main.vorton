use lib::{Dog, Describe}

fn show<T: Describe>(x: T) -> Str {
  x.describe()
}

fn main() {
  let d = Dog { name: "Rex" }
  print(show(d))
}
