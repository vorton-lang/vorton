// Unknown associated type should report E0511
trait Simple {
    fn value(self) -> Int
}

struct Foo {
    x: Int
}

impl Simple for Foo {
    fn value(self) -> Int { self.x }
}

// T::Output does not exist on Simple
fn use_it<T: Simple>(t: T) -> T::Output {
    42
}
