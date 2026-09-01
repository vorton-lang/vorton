// B-120: `var` is retired (axiom 8 — `mut` is the sole mutability keyword).
// After lexer removal `var` is a plain identifier, so `var x = 0` is a parse
// error (two consecutive idents). `let mut x = 0` is the one true spelling.
fn main() {
    var x = 0
    x = x + 1
    print("${x}")
}
