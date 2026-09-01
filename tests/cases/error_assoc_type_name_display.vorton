// expect-error: Item
trait Container {
    type Item
    fn get(self) -> Item
    fn put(mut self, item: Item) -> Unit
}

struct Box {
    val: Int
}

impl Container for Box {
    type Item = Int
    fn get(self) -> Int { self.val }
    fn put(mut self, item: Int) -> Unit { self.val = item }
}

// First call: get() returns Item, unifies Item = Int via annotation
// Second call: put expects Item (= Int), but we pass Str
fn transform<T: Container>(mut c: T) -> Unit {
    let x: Int = c.get()
    c.put("hello")
}

fn main() {}
