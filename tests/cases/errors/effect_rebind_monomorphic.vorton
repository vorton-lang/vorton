// expect-error: E0301
// The unannotated parameter belongs to the environment and must not become
// polymorphic merely because it also appears in the inferred fail payload.
fn raise_arg(value) {
    fail.raise(value)
}

fn main() {
    let first = raise_arg(1) catch { _ => () }
    let second = raise_arg("not-an-int") catch { _ => () }
    print(first)
    print(second)
}
