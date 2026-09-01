// expect-error: E0513
trait Container {
    type Item: Eq
    fn get(self) -> Item
}

struct NoEq {
    val: Int
}

struct BadBox {
    inner: NoEq
}

impl Container for BadBox {
    type Item = NoEq   // NoEq doesn't satisfy Eq bound -> E0513
    fn get(self) -> NoEq { self.inner }
}

fn main() {}
