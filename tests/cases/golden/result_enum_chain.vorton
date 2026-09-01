// User-defined Result enum (Ok/Err) constructed, matched, and threaded through
// helper functions WITHOUT passing closures as arguments (direct match-based
// chaining). Locks user-enum construct + match-payload parity on the LLVM
// backend.
//
// NOTE: the higher-order combinator form (and_then/map_ok taking `fn(v) {...}`
// closures) intermittently crashes/double-frees on LLVM — recorded under B-087 in
// docs/worker_feedback.md. This case stays first-order to be a stable parity lock.

enum Res { Ok(Int), Err(Str) }

impl Res {
    fn unwrap_or(self, d: Int) -> Int {
        match self {
            Res::Ok(v) => v,
            Res::Err(_) => d
        }
    }

    fn is_ok(self) -> Bool {
        match self {
            Res::Ok(_) => true,
            Res::Err(_) => false
        }
    }

    fn show(self) -> Str {
        match self {
            Res::Ok(v) => "ok(${v})",
            Res::Err(e) => "err(${e})"
        }
    }
}

fn step(x: Int) -> Res {
    if x < 100 { Res::Ok(x * 2) } else { Res::Err("too big") }
}

// first-order chaining: match the previous result, feed the next step manually
fn chain2(x: Int) -> Res {
    match step(x) {
        Res::Ok(v) => step(v),
        Res::Err(e) => Res::Err(e)
    }
}

fn chain3(x: Int) -> Res {
    match chain2(x) {
        Res::Ok(v) => Res::Ok(v + 1),
        Res::Err(e) => Res::Err(e)
    }
}

fn main() {
    print("step ok: ${step(5).show()}")             // step ok: ok(10)
    print("step err: ${step(500).show()}")          // step err: err(too big)

    print("chain2 ok: ${chain2(10).show()}")        // chain2 ok: ok(40)
    print("chain2 err: ${chain2(60).show()}")       // 60->120 ok, 120 too big => err
    print("chain3 ok: ${chain3(10).show()}")        // chain3 ok: ok(41)
    print("chain3 err: ${chain3(200).show()}")      // chain3 err: err(too big)

    print("unwrap ok: ${step(5).unwrap_or(-1)}")    // unwrap ok: 10
    print("unwrap err: ${step(500).unwrap_or(-1)}") // unwrap err: -1
    print("is_ok true: ${step(5).is_ok()}")         // is_ok true: true
    print("is_ok false: ${step(500).is_ok()}")      // is_ok false: false
}
