// Regression test for #52: effect annotation edge cases
// Tests multi-effect combinations, fail propagation, catch interaction

// Multiple effects in one annotation
fn read_or_fail(x: Int) -> Str with {console, fail<Str>} {
    if x < 0 { fail.raise("negative") }
    print("reading ${x.to_str()}")
    x.to_str()
}

// Catch removes fail effect — remaining is io
fn safe_read(x: Int) -> Str with {console} {
    read_or_fail(x) catch { _ => "default" }
}

// Effect propagation: caller inherits callee's effects
fn wrapper() -> Str with {console, fail<Str>} {
    read_or_fail(42)
}

// No annotation — effects inferred (backward compatible)
fn inferred_effects(x: Int) -> Str {
    read_or_fail(x) catch { _ => "caught" }
}

fn main() {
    print(safe_read(5))
    print(safe_read(-1))
    let w = wrapper() catch { e => "err: ${e}" }
    print(w)
    print(inferred_effects(10))
    print(inferred_effects(-1))
}
