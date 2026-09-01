// B-104 W4 regression: scalar mut-var reassignment drops the old boxed scalar.
//
// THE CHANGE THIS PINS: rc_stmt's Assign arm now, for a plain (non-auto-boxed) mut
// var holding a SCALAR (Int/Bool/Float), materialises the RHS, drops the OLD value,
// then stores.  This reclaims the `x = x + 1` mut-counter leak (INT①).
//
// THE UAF RISK THIS PINS (not covered by anf_temp_drop's bare counters): a SHARED
// scalar.  `let y = x` dup's x's box (clone-all-escape escape→Clone, rc=2).  A later
// `x = x + 1` drops the OLD x box — that must DECREMENT (rc 2→1), leaving y valid, not
// free it.  A wrong impl (dropping without the dup, or treating the old value as
// unshared/owned-once) frees y's value → native UAF (over-free aborts under RC); the
// Expected output pins y's surviving value.  Also pins the order: the RHS must be evaluated
// BEFORE the old-value drop (self-read `x = x + 1` reads the old box), else UAF.

// Plain counter: every `i = i + 1` / `acc = acc + i` drops the old box (W4 reclaim).
fn sum_to(n: Int) -> Int {
    let mut acc = 0
    let mut i = 0
    while i < n {
        acc = acc + i
        i = i + 1
    }
    acc
}

// Shared scalar: y holds a dup of x's box; reassigning x must keep y alive (rc 2→1).
fn shared_then_reassign() -> Int {
    let mut x = 42
    let y = x          // y dup's x's box (rc 2)
    x = x + 100        // drops OLD x box → rc 2→1, y stays valid
    let z = y          // z dup's the still-live box
    x + y + z          // 142 + 42 + 42 = 226
}

// Shared inside a loop: capture the counter's value before each bump.
fn snapshot_sum(n: Int) -> Int {
    let mut i = 0
    let mut total = 0
    while i < n {
        let snap = i       // dup of i's box
        total = total + snap
        i = i + 1          // drops old i box; snap (dup) stays valid through its use
    }
    total
}

// B-104 D2 (verifier-found latent UAF): a scalar binding whose init is `&&`/`||`
// holds the RHS box VERBATIM (phi, un-Cloned — the struct still owns it).  The
// W4 reassign-drop must NOT fire for it (binding not in the visible owned set):
// dropping would free obj's field box.  obj.flag must survive the reassign.
struct Gate { flag: Bool }

fn andor_init_reassign() -> Str {
    let g = Gate { flag: true }
    let cond = true
    let mut ok = cond && g.flag    // non-droppable init: holds g.flag's box verbatim
    ok = false                     // must NOT drop the old (borrowed) box
    "ok=${ok} flag=${g.flag}"
}

fn main() {
    print("sum=${sum_to(100)}")                   // sum=4950
    print("shared=${shared_then_reassign()}")     // shared=226
    print("snap=${snapshot_sum(10)}")             // snap=45
    print(andor_init_reassign())                  // ok=false flag=true

    // Bool + Float reassignment (scalar typeids 2 / for float, drop is a no-op free).
    let mut b = true
    b = false
    let mut f = 1.5
    f = f + 2.5
    print("b=${b} f=${f}")                        // b=false f=4

    // Direct shared-scalar at top level (no loop): a = b's box, mutate b, a survives.
    let mut p = 7
    let q = p
    p = p * 3
    print("p=${p} q=${q}")                        // p=21 q=7
}
