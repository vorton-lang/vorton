// #245: or-pattern alternatives carrying ctor-nested literal sub-patterns.
// Before the fix: (a) `some(1) | some(2)` emitted duplicate LLVM switch cases
// (or-pattern alternatives were invisible to the duplicate-tag detection) —
// invalid IR; (b) alternatives were only tag-tested, so `some(9)` matched
// `some(1) | some(2)`. Both backends must value-compare each alternative's
// full pattern and fall through alternative-by-alternative.
// Expected output is HAND-WRITTEN semantics (pre-fix oracle was the bug side).

// --- or-pattern, same ctor tag, literal fields ---
fn small(o: Int?) -> Str {
    match o {
        some(1) | some(2) => "small",
        some(n) => "n=${n}",
        none => "none",
    }
}

// --- or-pattern mixing a literal-field ctor with a field-less ctor ---
fn zero_or_none(o: Int?) -> Str {
    match o {
        some(0) | none => "zero-or-none",
        some(n) => "n=${n}",
    }
}

enum E2 {
    A(Int),
    B(Int),
    C,
}

// --- or-pattern with distinct tags + wildcard: previously switch-eligible,
// so the failed A(0) field check had no fall-through path ---
fn a0_or_b(e: E2) -> Str {
    match e {
        A(0) | B(_) => "a0-or-b",
        _ => "other",
    }
}

fn main() {
    print(small(some(1)))   // small
    print(small(some(2)))   // small
    print(small(some(9)))   // n=9
    print(small(none))      // none
    print(zero_or_none(some(0)))  // zero-or-none
    print(zero_or_none(none))     // zero-or-none
    print(zero_or_none(some(4)))  // n=4
    print(a0_or_b(A(0)))    // a0-or-b
    print(a0_or_b(A(5)))    // other
    print(a0_or_b(B(9)))    // a0-or-b
    print(a0_or_b(C))       // other
}
