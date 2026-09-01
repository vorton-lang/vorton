// Test: mut self in impl methods (alias for mut self)

struct Counter { value: Int }

impl Counter {
    fn get(self) -> Int { self.value }
    fn increment(mut self) { self.value = self.value + 1 }
    fn add(mut self, amount: Int) { self.value = self.value + amount }
}

fn main() {
    let mut c = Counter { value: 0 }
    c.increment()
    c.increment()
    assert(c.get() == 2, "mut self method modifies struct")

    c.add(10)
    assert(c.get() == 12, "mut self add method works")

    // mut self still works (backward compat)
    let mut c2 = Counter { value: 100 }
    c2.increment()
    assert(c2.get() == 101, "mut self still works")

    print("let_mut_method: all tests passed")
}
