// expect-error: E0513
trait Container {
    type Item
    fn get(self) -> Item
}

struct IntBox { val: Int }
impl Container for IntBox {
    type Item = Int
    fn get(self) -> Int { self.val }
}

struct StrBox { val: Str }
impl Container for StrBox {
    type Item = Str
    fn get(self) -> Str { self.val }
}

fn get_first_int<T: Container<Item = Int>>(c: T) -> Int {
    c.get()
}

fn main() {
    let s = StrBox { val: "hello" }
    get_first_int(s)  // Should fail: StrBox's Item = Str, not Int
}
