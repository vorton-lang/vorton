// B-122 negative test: SCC return type soundness
// Callee returns Int but caller expects Str — must report E0301.
// Before B-122 this was silently accepted (unsound).

fn caller_bad() -> Str {
    callee_int()
}

fn callee_int() {
    42
}
