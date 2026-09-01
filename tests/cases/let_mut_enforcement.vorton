struct Counter { value: Int }

impl Counter {
    fn get(self) -> Int { self.value }
    fn increment(mut self) { self.value = self.value + 1 }
}

fn main() {
    // let mut allows mutating methods
    let mut list = [1, 2, 3]
    list.push(4)
    assert(list.len() == 4, "push on let mut works")

    let mut m = map_new()
    m.insert("a", 1)
    assert(m.len() == 1, "insert on let mut map works")

    let mut s = set_new()
    s.insert(42)
    assert(s.len() == 1, "insert on let mut set works")

    // user-defined mut self method
    let mut c = Counter { value: 0 }
    c.increment()
    assert(c.get() == 1, "user mut self on let mut works")

    // let (immutable) can call non-mutating methods
    let list2 = [1, 2, 3]
    assert(list2.len() == 3, "len on let works")
    assert(list2.contains(2), "contains on let works")

    print("let_mut_enforcement: all tests passed")
}
