struct Bag<T> { items: List<T> }

impl<T: Eq> Bag {
    fn has(self: Bag<T>, item: T) -> Bool {
        for x in self.items {
            if x == item { return true }
        }
        false
    }
}

fn main() {
    let b = Bag { items: ["a", "b"] }
    print("has a: ${b.has("a")}")   // expect true
    print("has z: ${b.has("z")}")   // expect false
    let bi = Bag { items: [1, 2, 3] }
    print("has 2: ${bi.has(2)}")    // expect true
}
