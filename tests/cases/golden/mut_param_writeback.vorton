// B-087 gap 5 (#103): a mut value-type parameter that the callee REASSIGNS
// (x = new_val) must reflect back to the caller's variable. The backend boxes the
// mut param as a CELL (ptr-to-box) and shares the box when the caller passes a
// boxed var, so the callee's `x = new_val` writes through to the caller's cell.

fn bump(mut x: Int) {
    x = x + 100
}

fn set_to(mut x: Int, v: Int) {
    x = v
}

fn double_it(mut x: Int) {
    x = x * 2
    x = x + 1     // multiple reassigns
}

fn main() {
    let mut a = 5
    bump(a)
    print(a)        // 105

    let mut b = 10
    set_to(b, 42)
    print(b)        // 42

    let mut c = 7
    double_it(c)
    print(c)        // 15

    // chained: pass result through two mutators
    let mut d = 1
    bump(d)         // 101
    bump(d)         // 201
    print(d)        // 201
}
