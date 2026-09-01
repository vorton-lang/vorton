// expect-error: E0405
// B-056: Closure mutating captured outer `let mut` injects mut<T> effect.
// A pure module should reject a function whose body uses such a closure.

mod pure_mod requires {} {
    pub fn impure_closure() -> Int {
        let mut x = 0
        let bump = fn() { x = x + 1 }
        bump()
        x
    }
}
