trait Showable {
    fn show(self) -> Str
}

impl Showable for Int {
    fn show(self) -> Str { self.to_str() }
}

impl Showable for Str {
    fn show(self) -> Str { self }
}

// T: Showable appears only inside FnType parameter
fn apply_show<T: Showable>(f: fn(T) -> Str, x: T) -> Str {
    f(x)
}

fn main() {
    let result = apply_show(fn(x: Int) -> Str { x.show() }, 42)
    assert(result == "42", "apply_show with Int")

    let result2 = apply_show(fn(x: Str) -> Str { x.show() }, "hello")
    assert(result2 == "hello", "apply_show with Str")

    print("trait fn param: ok")
}
