// Regression C6: trait bound preserved through let-binding alias
trait Show {
    fn show(self) -> Str
}

struct Num { value: Int }

impl Show for Num {
    fn show(self) -> Str { "num" }
}

fn display<T: Show>(x: T) -> Str with {} {
    x.show()
}

fn main() {
    let f = display
    print(f(Num { value: 42 }))
}
