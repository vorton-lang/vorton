// Canary for the 0.1 Core -> Flow -> ownership -> materialized-HIR path.
// It combines exact custom-effect evidence, omitted trait defaults, delegate
// forwarding, and generated structural bodies in one observable program.
effect Step {
    fn add_one(value: Int) -> Int
}

trait Named {
    fn name(self) -> Str
}

trait Greeter: Named {
    fn greet(self) -> Str {
        "Hello ${self.name()}"
    }
}

struct Inner { value: Str }

impl Named for Inner {
    fn name(self) -> Str { self.value }
}

impl Greeter for Inner {}

struct Wrapper { inner: Inner }

impl Wrapper {
    delegate inner: Named
}

struct TupleBox { value: (Str, Bool) }

fn main() {
    let handled = handle {
        Step.add_one(4)
    } with {
        Step.add_one(value) => value + 1,
    }
    let inner = Inner { value: "Alice" }
    assert(inner.greet() == "Hello Alice", "trait default body")
    let wrapper = Wrapper { inner: Inner { value: "Alice" } }
    assert(wrapper.name() == "Alice", "delegate body")
    let original = TupleBox { value: ("tuple", true) }
    let copied = original.clone()
    assert(copied == original, "derived deep clone")
    assert(copied.debug().len() > 0, "derived debug body")
    print("ownership_core_cutover:${handled}")
}
