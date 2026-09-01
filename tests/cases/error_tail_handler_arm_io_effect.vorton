// Audit #258 negative: effects performed by a tail-resumptive handler arm
// escape the handle and must remain visible to the enclosing signature.

effect Probe {
    fn value() -> Int
}

fn pure_tail_arm_io() -> Int with {} {
    handle {
        Probe.value()
    } with {
        Probe.value() => {
            print("tail arm")
            1
        },
    }
}

fn main() {}
