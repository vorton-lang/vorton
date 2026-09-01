// B-083 #1 regression (move path): when a closure is the LAST use of a captured
// heap value in its (non-loop) scope, the single owned reference is moved into
// the closure with NO dup.  The closure must then be the sole owner; using it
// must produce the right value, and there must be no double-free (the enclosing
// scope must NOT also drop the moved-out binding).

fn invoke(f: fn() -> Str) -> Str { f() }

fn build() -> fn() -> Str {
    let payload = "P-${7 * 6}"        // heap Str
    // `payload` is never used again in this scope after the closure → last use
    // → moved into the closure, no dup.
    fn() -> Str { "got:${payload}" }
}

fn main() {
    let f = build()
    print(invoke(f))

    // Same shape but capture is genuinely single-use within main's scope.
    let only = "O-${1 + 1}"
    let g = fn() -> Str { "only:${only}" }
    print(invoke(g))
}
