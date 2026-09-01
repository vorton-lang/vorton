// Multiple type params with same-named associated types must resolve correctly
// via qualified paths (T::Item vs U::Item)

trait Source {
    type Item
    fn get(self) -> Item
}

trait Sink {
    type Item
    fn put(self, val: Item) -> Unit
}

struct IntSource { val: Int }
impl Source for IntSource {
    type Item = Int
    fn get(self) -> Int { self.val }
}

struct StrSink { data: Str }
impl Sink for StrSink {
    type Item = Str
    fn put(self, val: Str) -> Unit { }
}

// T::Item = Int, U::Item = Str — must resolve to respective trait bounds
fn transfer<T: Source<Item = Int>, U: Sink<Item = Str>>(src: T, sink: U) -> Int {
    let v = src.get()
    v
}

fn main() {
    let s = IntSource { val: 42 }
    let k = StrSink { data: "" }
    let result = transfer(s, k)
    assert(result == 42, "qualified assoc type should resolve correctly")
    print("assoc_type_qualified_multi: ok")
}
