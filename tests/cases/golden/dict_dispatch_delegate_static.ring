// Delegate-expanded Eq dispatch where dict_param is a static dict name
// (e.g. __Inner_Eq) rather than a __ring_T_X parameter.  Both == and != route
// through the exact Eq.eq slot; != negates that result at the operator site.

struct Inner { x: Int }

impl Eq for Inner {
    fn eq(self, other: Inner) -> Bool {
        self.x == other.x
    }
}

struct Wrapper { inner: Inner }

impl Wrapper {
    delegate inner: Eq
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
