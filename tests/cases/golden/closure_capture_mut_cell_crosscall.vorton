// B-091 regression (cross-call boundary): a closure that writes through a captured
// `let mut` is passed as an argument to another function, invoked there, then
// invoked again in the original scope.  The shared cell must survive being passed
// across the call boundary and accumulate every write.

fn apply_twice(f: fn() -> Int) -> Int {
    let a = f()
    f()
}

fn main() {
    let mut total = 0
    let bump = fn() -> Int { total = total + 10; total }
    let r = apply_twice(bump)   // two writes through the cell: total 10, then 20
    let s = bump()              // third write: total 30
    print("${total}")           // 30
    print("${r}")               // 20 — apply_twice's 2nd call result
    print("${s}")               // 30
}
