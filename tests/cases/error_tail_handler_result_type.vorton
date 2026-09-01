// Audit #258 negative: a tail-resumptive handler arm supplies the operation's
// resume value, so its result must match the operation return type.

effect Probe {
    fn value() -> Int
}

fn mismatched_tail_arm() -> Int with {} {
    handle {
        Probe.value()
    } with {
        Probe.value() => "wrong type",
    }
}

fn main() {}
