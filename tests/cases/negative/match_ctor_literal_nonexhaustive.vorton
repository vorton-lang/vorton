// #245 exhaustiveness lock: a ctor-nested literal sub-pattern must NOT count
// as full coverage of that ctor — `some(0)` + `none` without a fallback is
// non-exhaustive (missing some(_)).
fn f(o: Int?) -> Str {
    match o {
        some(0) => "zero",
        none => "none",
    }
}

fn main() {
    print(f(some(0)))
}
