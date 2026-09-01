// B-115: an interpolation opened with `${` but never closed before EOF must
// produce a dedicated diagnostic whose span points at the opening `${`,
// instead of only a generic parser error at EOF.
fn main() {
    let foo = 1
    let s = "${foo
