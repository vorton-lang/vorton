// #245: a ctor-nested literal sub-pattern (e.g. `some(0)`) must COMPARE the
// value — check_nested_ctor_tags treated Pattern::Literal as a no-op, so the
// first same-tag arm swallowed every value (`some(7)` printed "zero"). Same
// family: a tuple element's ctor sub-pattern was only tag-checked one level
// deep (`(Neg(Lit(0)), _)` never verified the inner Lit), and a ctor field
// holding a tuple pattern (`P((0, y))`) was never checked at all.
// Expected output is HAND-WRITTEN semantics (the pre-fix LLVM oracle was the
// bug side) — both backends must agree with it.

// --- ctor-nested Int literal + multi-literal fall-through ---
fn int_case(o: Int?) -> Str {
    match o {
        some(0) => "zero",
        some(1) => "one",
        some(n) => "n=${n}",
        none => "none",
    }
}

// --- ctor-nested Str literal ---
fn str_case(o: Str?) -> Str {
    match o {
        some("hi") => "greeting",
        some(s) => "s=${s}",
        none => "none",
    }
}

// --- ctor-nested Bool literal ---
fn bool_case(o: Bool?) -> Str {
    match o {
        some(true) => "yes",
        some(false) => "no",
        none => "none",
    }
}

// --- ctor-nested Float literal ---
fn float_case(o: Float?) -> Str {
    match o {
        some(1.5) => "one-half",
        some(_) => "other",
        none => "none",
    }
}

enum Expr {
    Lit(Int),
    Neg(Expr),
}

// --- tuple element ctor sub-pattern: inner tags AND literals recursively ---
fn tuple_ctor(p: (Expr, Int)) -> Str {
    match p {
        (Neg(Lit(0)), _) => "neg-zero",
        (Neg(Lit(n)), k) => "neg ${n} k=${k}",
        (Lit(n), k) => "lit ${n} k=${k}",
        _ => "other",
    }
}

// --- guard + ctor-nested literal combination ---
fn guard_case(o: Int?, flag: Bool) -> Str {
    match o {
        some(0) if flag => "zero-flag",
        some(0) => "zero",
        some(n) => "n=${n}",
        none => "none",
    }
}

enum Wrap {
    P((Int, Int)),
    Q,
}

// --- ctor field holding a tuple pattern with a literal element ---
fn tuple_in_ctor(w: Wrap) -> Str {
    match w {
        P((0, y)) => "p0 y=${y}",
        P((x, y)) => "p ${x} ${y}",
        Q => "q",
    }
}

fn main() {
    print(int_case(some(7)))    // n=7
    print(int_case(some(0)))    // zero
    print(int_case(some(1)))    // one
    print(int_case(none))       // none
    print(str_case(some("hi"))) // greeting
    print(str_case(some("yo"))) // s=yo
    print(bool_case(some(true)))  // yes
    print(bool_case(some(false))) // no
    print(bool_case(none))        // none
    print(float_case(some(1.5)))  // one-half
    print(float_case(some(2.5)))  // other
    print(tuple_ctor((Neg(Lit(0)), 3)))       // neg-zero
    print(tuple_ctor((Neg(Lit(4)), 3)))       // neg 4 k=3
    print(tuple_ctor((Neg(Neg(Lit(1))), 5)))  // other
    print(tuple_ctor((Lit(9), 2)))            // lit 9 k=2
    print(guard_case(some(0), true))   // zero-flag
    print(guard_case(some(0), false))  // zero
    print(guard_case(some(3), true))   // n=3
    print(tuple_in_ctor(P((0, 5))))    // p0 y=5
    print(tuple_in_ctor(P((3, 4))))    // p 3 4
    print(tuple_in_ctor(Q))            // q
}
