// B-087 gap 1: a polymorphic function with a trait bound used as a FIRST-CLASS
// value (passed to a higher-order fn). The checker tags the Ident with
// dict_closure_dicts so the value carries the resolved trait dict. The bootstrap
// backend wraps it in `(__ring_a0) => fn(__ring_a0, <dict>)`. The LLVM gen_ident dropped dict_closure_dicts
// (the `..` in its signature) so the function value had the wrong call signature.

trait Describe { fn describe(self) -> Str }

struct Dog { name: Str }
impl Describe for Dog { fn describe(self) -> Str { "dog:${self.name}" } }

// generic function with a trait bound — used below as a first-class value
fn show<T: Describe>(x: T) -> Str with {} { x.describe() }

// higher-order fn: takes a fn value and applies it
fn apply_show(f: fn(Dog) -> Str, d: Dog) -> Str { f(d) }

fn main() {
    let dog = Dog{ name: "rex" }
    // `show` here is a polymorphic fn value → dict_closure_dicts must be threaded
    print(apply_show(show, dog))   // dog:rex
}
