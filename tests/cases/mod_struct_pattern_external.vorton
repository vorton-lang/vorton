mod inner {
    pub struct Pair { a: Str, b: Str }

    pub fn make(a: Str, b: Str) -> Pair {
        Pair { a: a, b: b }
    }
}

fn describe(p: inner::Pair) -> Str {
    match p {
        inner::Pair { a, b } => "${a}-${b}",
    }
}

fn main() {
    let p = inner::make("hello", "world")
    let desc = describe(p)
    assert(desc == "hello-world", "external qualified struct pattern")
    print("mod struct pattern external: ok")
}
