// An unannotated top-level parameter is monomorphic. Body inference may refine
// it from ?T to List<?U>, but rebind must not quantify the newly exposed ?U:
// the first call fixes it to Int and the second call must be rejected.

fn discard_list<T>(values: List<T>) -> Unit {}

fn consume(values) -> Unit {
    discard_list(values)
}

fn main() {
    consume([1])
    consume(["one"])
}
