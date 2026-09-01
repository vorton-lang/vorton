// B-163 Phase 1 step 7 regression: per-type drop functions + user Drop impl
// (emit_drop_functions port).  Locks:
//   1. user Drop fires at scope end
//   2. user drop body runs BEFORE recursive field drops (outer then inner)
//   3. Drop type inside an enum payload is released via the enum's drop fn
//   4. Drop type inside a List is released via the runtime container drop
//   5. move (`let b = a`) does not double-fire the user drop
// Runs identically on both backends (diff harness locks parity).

struct Tracker {
    tag: Str
}

impl Drop for Tracker {
    fn drop(self) {
        print("drop ${self.tag}")
    }
}

struct Outer {
    label: Str,
    inner: Tracker
}

impl Drop for Outer {
    fn drop(self) {
        print("drop outer ${self.label}")
    }
}

enum Holder {
    Wrapped { t: Tracker },
    Empty,
}

fn scope_end() {
    print("scope begin")
    let t = Tracker { tag: "scoped" }
    print("scope end")
}

fn field_recursion() {
    print("field begin")
    let o = Outer { label: "o1", inner: Tracker { tag: "inner" } }
    print("field end")
}

fn enum_payload() {
    print("enum begin")
    let h = Holder::Wrapped { t: Tracker { tag: "payload" } }
    print("enum end")
}

fn list_containment() {
    print("list begin")
    let l = [Tracker { tag: "in-list" }]
    print("list end")
}

fn move_no_double() {
    print("move begin")
    let a = Tracker { tag: "moved" }
    let b = a
    print("move end")
}

fn main() {
    scope_end()
    field_recursion()
    enum_payload()
    list_containment()
    move_no_double()
    print("done")
}
