// Basic associated type: trait declares type Item, impl assigns concrete type
trait Container {
    type Item
    fn get(self) -> Item
}

struct IntBox {
    value: Int
}

impl Container for IntBox {
    type Item = Int
    fn get(self) -> Int {
        self.value
    }
}

struct StrBox {
    value: Str
}

impl Container for StrBox {
    type Item = Str
    fn get(self) -> Str {
        self.value
    }
}

fn main() {
    let ib = IntBox { value: 42 }
    let sb = StrBox { value: "hello" }
    assert(ib.get() == 42, "IntBox.get should return 42")
    assert(sb.get() == "hello", "StrBox.get should return hello")
    print("assoc type basic: ok")
}
