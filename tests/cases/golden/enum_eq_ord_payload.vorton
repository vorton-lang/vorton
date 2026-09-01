// #159 #160 regression: enum Eq/Ord derive must compare payload fields,
// not just tags.  Covers:
//   - some(1) == some(2) must be false (#159)
//   - some(1) == some(1) must be true
//   - none == none must be true (field-less variant unchanged)
//   - Wrapper::Val(1) < Wrapper::Val(2) must be true (#160)
//   - multi-field enum variant comparison
//   - generic enum Eq/Ord with payload

enum Color {
    Red,
    Green,
    Blue,
}

enum Shape {
    Circle(Int),
    Rect(Int, Int),
    Dot,
}

enum Wrapper {
    Empty,
    Val(Int),
    Pair(Int, Int),
}

fn main() {
    // --- Eq on Option (built-in, single payload) ---
    let a: Int? = some(1)
    let b: Int? = some(2)
    let c: Int? = some(1)
    let d: Int? = none
    let e: Int? = none

    print("opt_eq_diff: ${a == b}")       // false — #159 fix
    print("opt_eq_same: ${a == c}")       // true
    print("opt_ne_diff: ${a != b}")       // true
    print("none_eq: ${d == e}")           // true

    // --- Eq on field-less enum ---
    let r1 = Color::Red
    let r2 = Color::Red
    let g = Color::Green
    print("color_eq: ${r1 == r2}")        // true
    print("color_ne: ${r1 == g}")         // false

    // --- Ord on field-less enum ---
    print("color_lt: ${r1 < g}")          // true (Red=0 < Green=1)
    print("color_gt: ${g > r1}")          // true

    // --- Eq on multi-field enum variant ---
    let s1 = Shape::Rect(3, 4)
    let s2 = Shape::Rect(3, 4)
    let s3 = Shape::Rect(3, 5)
    let s4 = Shape::Circle(3)
    let s5 = Shape::Dot
    let s6 = Shape::Dot
    print("shape_eq_same: ${s1 == s2}")   // true
    print("shape_eq_diff: ${s1 == s3}")   // false (second field differs)
    print("shape_eq_cross: ${s1 == s4}")  // false (different variants)
    print("shape_dot_eq: ${s5 == s6}")    // true

    // --- Ord on multi-field enum variant ---
    print("shape_cmp_same: ${s1 < s2}")   // false (equal)
    print("shape_cmp_f2: ${s1 < s3}")     // true (3,4 < 3,5 — second field)
    print("shape_cmp_cross: ${s4 < s1}")  // true (Circle=0 < Rect=1)

    // --- Ord on single-field enum (the key #160 test) ---
    let w1 = Wrapper::Val(10)
    let w2 = Wrapper::Val(20)
    let w3 = Wrapper::Val(10)
    let w4 = Wrapper::Empty
    print("wrap_lt: ${w1 < w2}")          // true — #160 fix
    print("wrap_gt: ${w2 > w1}")          // true
    print("wrap_eq: ${w1 <= w3}")         // true
    print("wrap_ne: ${w1 >= w2}")         // false
    print("wrap_cross: ${w4 < w1}")       // true (Empty=0 < Val=1)

    // --- Ord on multi-field enum variant ---
    let p1 = Wrapper::Pair(1, 2)
    let p2 = Wrapper::Pair(1, 3)
    let p3 = Wrapper::Pair(2, 1)
    print("pair_lt_f2: ${p1 < p2}")       // true (first field same, second 2<3)
    print("pair_lt_f1: ${p1 < p3}")       // true (first field 1<2)
    print("pair_eq: ${p1 == p1}")         // true

    // --- Nested Option Eq ---
    let n1: Str? = some("hello")
    let n2: Str? = some("hello")
    let n3: Str? = some("world")
    print("str_opt_eq: ${n1 == n2}")      // true
    print("str_opt_ne: ${n1 == n3}")      // false

    print("enum_eq_ord_payload: done")
}
