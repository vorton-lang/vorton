// B-137: effect propagation through return expressions
// collect_local_calls must recurse into ReturnExpr to find callees

enum MyErr {
    Oops { msg: Str },
}

fn raises_fail() -> Int {
    fail.raise(MyErr::Oops { msg: "boom" })
}

fn via_return(x: Int) -> Int {
    if x < 0 {
        return raises_fail()
    }
    x
}

fn main() {
    let result = via_return(-1) catch {
        MyErr::Oops { msg } => -1,
    }
    assert(result == -1, "effect propagated through return")

    let ok = via_return(42) catch {
        MyErr::Oops { msg } => -1,
    }
    assert(ok == 42, "normal path works")

    print("return_call_effect: all tests passed")
}
