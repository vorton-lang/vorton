// Audit #255/#256 regressions:
//   * an enum's user Drop body runs before its live variant payload is dropped
//   * builtin Result uses the same generated enum glue, so both Ok and Err
//     recursively release owned payloads

struct Tracker {
    tag: Str
}

impl Drop for Tracker {
    fn drop(self) {
        print("drop payload ${self.tag}")
    }
}

// Result constructor calls take ownership through the regular Perceus clone
// contract.  Keep the observable Drop one level below a plain wrapper so this
// regression isolates Result's recursive glue from Drop-type move checking.
struct Payload {
    tracker: Tracker
}

enum Envelope {
    Wrapped { tracker: Tracker },
    Empty,
}

impl Drop for Envelope {
    fn drop(self) {
        print("drop envelope")
    }
}

fn user_enum_payload() {
    print("enum begin")
    let value = Envelope::Wrapped { tracker: Tracker { tag: "enum" } }
    print("enum end")
}

fn result_ok_payload() {
    print("result ok begin")
    let value: Result<Payload, Payload> = Result::Ok(Payload {
        tracker: Tracker { tag: "ok" }
    })
    print("result ok end")
}

fn result_err_payload() {
    print("result err begin")
    let value: Result<Payload, Payload> = Result::Err(Payload {
        tracker: Tracker { tag: "err" }
    })
    print("result err end")
}

fn main() {
    user_enum_payload()
    result_ok_payload()
    result_err_payload()
    print("done")
}
