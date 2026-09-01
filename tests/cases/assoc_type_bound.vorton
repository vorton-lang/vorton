// Associated type with bounds: type Item: Eq works when concrete type implements Eq
trait Container {
    type Item: Eq
    fn get(self) -> Item
}

struct IntBox {
    value: Int
}

// Int implements Eq, so this should pass the bound check
impl Container for IntBox {
    type Item = Int
    fn get(self) -> Int { self.value }
}

struct StrBox {
    value: Str
}

// Str implements Eq, so this should pass the bound check
impl Container for StrBox {
    type Item = Str
    fn get(self) -> Str { self.value }
}

fn main() {
    let ib = IntBox { value: 42 }
    let sb = StrBox { value: "hello" }
    assert(ib.get() == 42, "IntBox.get should return 42")
    assert(sb.get() == "hello", "StrBox.get should return hello")
    print("assoc type bound: ok")
}
