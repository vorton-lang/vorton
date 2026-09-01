// Basic match guards on a non-enum (Int) scrutinee: an arm matches iff its
// pattern matches AND its guard is true; a false guard falls through to the
// next arm. The LLVM backend must re-test pattern+guard on fall-through.
fn classify(n: Int) -> Str {
    match n {
        x if x > 100 => "huge",
        x if x > 10 => "medium",
        x if x > 0 => "small",
        _ => "non-positive"
    }
}

fn main() {
    print(classify(500))   // huge
    print(classify(50))    // medium
    print(classify(5))     // small
    print(classify(0))     // non-positive
    print(classify(-3))    // non-positive
}
