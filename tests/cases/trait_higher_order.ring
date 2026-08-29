trait Show {
    fn show(self) -> Str
}

struct Num { val: Int }

impl Show for Num {
    fn show(self) -> Str { "num" }
}

fn display<T: Show>(item: T) -> Str with {} {
    item.show()
}

fn apply(f: fn(Num) -> Str, item: Num) -> Str {
    f(item)
}

fn main() {
    let result = apply(display, Num { val: 1 })
    print(result)
}
