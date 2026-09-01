// Audit #265 regression: a tail-resumptive handler arm for a Unit-returning
// operation supplies no information through its resume value. Its result is
// discarded exactly like a statement-position value, so any arm result type is
// accepted. The original #258 arm contract unified the arm result with Unit
// and rejected this program with E0301 (cannot unify Str with ()).

effect Trace {
    fn emit(msg: Str) -> Unit
}

fn traced() -> Int with {Trace} {
    Trace.emit("begin")
    41 + 1
}

fn main() {
    let r = handle {
        traced()
    } with {
        Trace.emit(m) => {
            print("trace:${m}")
            "ignored"
        },
    }
    assert(r == 42, "handle result comes from the handled body")
    print("handler_unit_op_arm_discard: all tests passed")
}
