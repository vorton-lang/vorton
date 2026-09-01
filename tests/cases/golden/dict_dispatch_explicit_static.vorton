// Explicit Eq forwarding where the child dictionary is static.

struct Inner { x: Int }

impl Eq for Inner {
    fn eq(self, other: Inner) -> Bool {
        self.x == other.x
    }
}

struct Wrapper { inner: Inner }

impl Eq for Wrapper {
    fn eq(self, other: Wrapper) -> Bool {
        self.inner == other.inner
    }
}

fn main() {
    let a = Wrapper { inner: Inner { x: 42 } }
    let b = Wrapper { inner: Inner { x: 42 } }
    let c = Wrapper { inner: Inner { x: 99 } }
    print("eq=${a == b}")
    print("neq=${a != c}")
    print("eq2=${a == c}")
    print("neq2=${a != b}")
}
