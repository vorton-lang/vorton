// expect-error: E0105
// impl target type args must be type variables declared on the impl,
// not concrete types like Int.

trait Show {
    fn show(self) -> Str
}

struct Wrapper<T> {
    value: T
}

impl<T> Show for Wrapper<Int> {
    fn show(self) -> Str {
        "wrapper"
    }
}

fn main() {
    let w = Wrapper { value: 42 }
    print(w.show())
}
