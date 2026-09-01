// B-100 P1.1 parity: explicit clone API for structs and enums.
// Verifies clone produces independent copies.

struct Point { x: Int, y: Int }

enum Color { Red, Green, Blue }

enum Shape { Circle(Int), Rect(Int, Int) }

fn main() {
    // struct clone
    let p1 = Point { x: 1, y: 2 }
    let p2 = p1.clone()
    print("clone_eq=${p1 == p2}")                 // clone_eq=true
    print("p1_x=${p1.x}")                        // p1_x=1
    print("p2_x=${p2.x}")                        // p2_x=1

    // enum unit variant clone
    let c1 = Color::Red
    let c2 = c1.clone()
    print("color_eq=${c1 == c2}")                 // color_eq=true

    // enum with payload clone
    let s1 = Circle(10)
    let s2 = s1.clone()
    match s2 {
        Circle(r) => print("circle_r=${r}"),      // circle_r=10
        Rect(_, _) => print("circle_r=FAIL"),
    }

    // clone with two-field payload
    let s3 = Rect(3, 4)
    let s4 = s3.clone()
    match s4 {
        Rect(w, h) => print("rect=${w},${h}"),    // rect=3,4
        Circle(_) => print("rect=FAIL"),
    }

    // struct clone independence: two independent copies
    let a = Point { x: 10, y: 20 }
    let b = a.clone()
    print("a_x=${a.x} b_x=${b.x}")               // a_x=10 b_x=10
    print("ab_eq=${a == b}")                      // ab_eq=true
}
