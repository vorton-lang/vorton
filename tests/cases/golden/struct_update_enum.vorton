// Struct update syntax { ..base, field: new } including nested structs and
// spread from a function-call expression, plus complex enum variants with named
// fields, mixed positional/recursive payloads, and matching that rebuilds
// variants. Exercises record-copy lowering and enum variant construction/field
// ordering.

struct Point { x: Int, y: Int }
struct Rect { origin: Point, w: Int, h: Int }

enum Shape {
    Dot,
    Circle { center: Point, r: Int },
    Box { rect: Rect, label: Str },
    Group { items: List<Shape> }
}

fn make_point(x: Int, y: Int) -> Point {
    Point { x, y }
}

fn area(s: Shape) -> Int {
    match s {
        Shape::Dot => 0,
        Shape::Circle { center, r } => 3 * r * r,
        Shape::Box { rect, label } => rect.w * rect.h,
        Shape::Group { items } => {
            let mut total = 0
            for it in items {
                total = total + area(it)
            }
            total
        }
    }
}

// rebuild a shape, shifting any embedded point/rect origin by dx (struct update)
fn shift(s: Shape, dx: Int) -> Shape {
    match s {
        Shape::Dot => Shape::Dot,
        Shape::Circle { center, r } => Shape::Circle {
            center: Point { ..center, x: center.x + dx },
            r: r
        },
        Shape::Box { rect, label } => Shape::Box {
            rect: Rect { ..rect, origin: Point { ..rect.origin, x: rect.origin.x + dx } },
            label: "${label}*"
        },
        Shape::Group { items } => {
            let mut out: List<Shape> = []
            for it in items {
                out.push(shift(it, dx))
            }
            Shape::Group { items: out }
        }
    }
}

fn describe(s: Shape) -> Str {
    match s {
        Shape::Dot => "dot",
        Shape::Circle { center, r } => "circle@(${center.x},${center.y})r${r}",
        Shape::Box { rect, label } => "box[${label}]@(${rect.origin.x},${rect.origin.y})",
        Shape::Group { items } => "group(${items.len()})"
    }
}

fn main() {
    // basic struct update, single + multi field, complex spread source
    let p = Point { x: 1, y: 2 }
    let q = Point { ..p, x: 10 }
    print("q: (${q.x},${q.y})")             // q: (10,2)

    let r = Rect { origin: make_point(0, 0), w: 4, h: 5 }
    let r2 = Rect { ..r, w: 40, h: 50 }
    print("r2: ${r2.w}x${r2.h}@(${r2.origin.x})")   // r2: 40x50@(0)

    let spread = Point { ..make_point(1, 2), x: 100 }
    print("spread: (${spread.x},${spread.y})")      // spread: (100,2)

    // complex enum variants
    let g = Shape::Group { items: [
        Shape::Circle { center: Point { x: 1, y: 1 }, r: 2 },
        Shape::Box { rect: Rect { origin: Point { x: 3, y: 3 }, w: 4, h: 5 }, label: "a" },
        Shape::Dot
    ] }
    print("area: ${area(g)}")               // area: 32

    // shift rebuilds nested variants via struct update
    let g2 = shift(g, 10)
    print("desc after shift: ${describe(g2)}")      // desc after shift: group(3)

    let circ = Shape::Circle { center: Point { x: 5, y: 5 }, r: 3 }
    let circ2 = shift(circ, 7)
    print(describe(circ2))                  // circle@(12,5)r3

    let bx = Shape::Box { rect: Rect { origin: Point { x: 2, y: 2 }, w: 1, h: 1 }, label: "L" }
    print(describe(shift(bx, 100)))         // box[L*]@(102,2)
}
