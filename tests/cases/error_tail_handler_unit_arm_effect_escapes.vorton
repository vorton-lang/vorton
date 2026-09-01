// Audit #265 negative: the Unit-return exemption waives only the arm VALUE
// contract (the resume value carries no information). Effects performed by
// the arm still escape the handle and must remain visible to the enclosing
// signature, exactly as for non-Unit operations.

effect Notify {
    fn ping(msg: Str) -> Unit
}

fn pure_unit_tail_arm_io() -> Int with {} {
    handle {
        Notify.ping("hello")
        7
    } with {
        Notify.ping(msg) => {
            print("ping arm")
            "discarded"
        },
    }
}

fn main() {}
