trait Named {
    fn name(self) -> Str
}

struct Inner { value: Str }
struct Wrapper { inner: Inner }

impl Wrapper {
    delegate inner: Named
}

fn main() {}
