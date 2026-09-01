// Audit #258 negative: the operation return type is instantiated by the
// handled body's concrete effect arguments, not independently by the arm.

effect GenericProbe<T> {
    fn value() -> T
}

fn generic_int() -> Int with {GenericProbe<Int>} {
    GenericProbe.value()
}

fn generic_mismatched_tail_arm() -> Int with {} {
    handle {
        generic_int()
    } with {
        GenericProbe.value() => "wrong type",
    }
}

fn main() {}
