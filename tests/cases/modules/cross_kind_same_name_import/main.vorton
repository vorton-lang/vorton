// B-107 lock (5cf55aa review concern 3): the resolver plan judges ambiguity
// per (frame, local, namespace), so importing struct Foo and enum Foo under
// one spelling is legal — they occupy the Struct and Enum namespaces
// independently. `impl Foo` resolves struct-first, matching
// resolve_nominal_identity's registration order (structs before enums);
// enum member access still reaches b::Foo through the Enum namespace.
use a::{Foo, make_struct}
use b::{Foo, make_enum}

impl Foo {
    fn doubled(self) -> Int {
        self.v * 2
    }
}

fn main() {
    print(make_struct(21).doubled())
    match make_enum() {
        Foo::Zed => print(1)
    }
}
