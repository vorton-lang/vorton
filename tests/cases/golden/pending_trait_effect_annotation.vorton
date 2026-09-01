trait Marker {
    fn marker(self) -> Int
}

impl Marker for Int {
    fn marker(self) -> Int { self }
}

fn bounded_effect<T: Marker>() -> Unit with {fail<T>} {
    ()
}

fn caller() -> Unit with {fail<Int>} {
    // T is hidden from params/return and is supplied only by the declared
    // effect payload.  Owner drain must happen after that payload unification.
    bounded_effect()
}

fn main() {
    caller()
    print("effect-annotation=ok")
}
