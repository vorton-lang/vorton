// B-091 regression (factory counter): a function returns a closure that writes
// through a captured `let mut`.  The boxed cell must OUTLIVE the factory call
// (it is moved into the returned closure as its sole owner — Perceus last-use
// move is correct here) and accumulate across invocations.  Two independent
// counters must not share state (each `make_counter` allocates its own cell).

fn make_counter() -> fn() -> Int {
    let mut n = 0
    fn() -> Int { n = n + 1; n }
}

fn main() {
    let c = make_counter()
    print("${c()}")      // 1
    print("${c()}")      // 2
    print("${c()}")      // 3
    let d = make_counter()
    print("${d()}")      // 1 — independent cell
    print("${c()}")      // 4 — c's cell kept its own count
}
