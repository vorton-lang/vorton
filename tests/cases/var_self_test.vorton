// Test: mut self in impl methods + mut parameters

struct Counter {
  count: Int,
  name: Str
}

impl Counter {
  fn increment(mut self) {
    self.count = self.count + 1
  }

  fn add(mut self, amount: Int) {
    self.count = self.count + amount
  }

  fn set_name(mut self, new_name: Str) {
    self.name = new_name
  }

  fn get_count(self) -> Int {
    self.count
  }
}

// Test: nested field access mutation
struct Inner {
  value: Int
}

struct Outer {
  inner: Inner,
  label: Str
}

impl Outer {
  fn set_inner_value(mut self, v: Int) {
    self.inner.value = v
  }
}

// Test: mut parameter in regular function
fn double_in_place(mut x: Int) -> Int {
  x = x * 2
  x
}

fn main() {
  let mut c = Counter { count: 0, name: "test" }
  assert(c.get_count() == 0, "initial count")

  c.increment()
  assert(c.get_count() == 1, "after increment")

  c.add(5)
  assert(c.get_count() == 6, "after add 5")

  c.set_name("updated")
  assert(c.name == "updated", "name changed")

  // Nested field mutation
  let mut o = Outer { inner: Inner { value: 10 }, label: "hi" }
  o.set_inner_value(42)
  assert(o.inner.value == 42, "nested field mutation")

  // mut parameter
  let result = double_in_place(7)
  assert(result == 14, "mut param double")

  print("all var_self tests passed")
}
