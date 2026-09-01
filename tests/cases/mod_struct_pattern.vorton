mod inner {
    pub struct Pair { a: Str, b: Str }

    pub fn swap(p: Pair) -> Pair {
        match p {
            Pair { a, b } => Pair { a: b, b: a },
        }
    }
}

fn main() {
    let p = inner::Pair { a: "hello", b: "world" }
    let swapped = inner::swap(p)
    assert(swapped.a == "world", "a should be world")
    assert(swapped.b == "hello", "b should be hello")

    print("mod struct pattern: ok")
}
