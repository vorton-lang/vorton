// B-100 P1.3 R3 adversarial: complex match patterns — or-patterns with enum,
// nested tuple + enum destructuring, struct patterns with guards.
//
// Exercises:
//   * Or-pattern on enum variants (payloadless and with payload via wildcard)
//   * Nested tuple matching with different shapes
//   * Option inside tuple — (some(x), none) patterns
//   * Struct pattern with guard condition
//   * Match on enum with named fields + guard
//   * Deeply nested patterns

enum Dir { North, South, East, West }

fn is_horizontal(d: Dir) -> Bool {
    match d {
        Dir::East | Dir::West => true,
        Dir::North | Dir::South => false,
    }
}

fn is_vertical(d: Dir) -> Bool {
    match d {
        Dir::North | Dir::South => true,
        Dir::East | Dir::West => false,
    }
}

// Nested option matching
fn both_or_none(a: Option<Int>, b: Option<Int>) -> Str {
    let pair = (a, b)
    match pair {
        (some(x), some(y)) => "both: ${x + y}",
        (some(x), none) => "left: ${x}",
        (none, some(y)) => "right: ${y}",
        (none, none) => "neither",
    }
}

// Struct with guard
struct Score {
    name: Str,
    value: Int,
}

fn rate(s: Score) -> Str {
    match s {
        Score { name, value } if value >= 90 => "${name}: excellent",
        Score { name, value } if value >= 70 => "${name}: good",
        Score { name, value } if value >= 50 => "${name}: pass",
        Score { name, value } => "${name}: fail (${value})",
    }
}

// Enum with named fields + match + guard
enum Shape {
    Circle { radius: Int },
    Rect { w: Int, h: Int },
}

fn describe_shape(s: Shape) -> Str {
    match s {
        Shape::Circle { radius } if radius > 10 => "big circle r=${radius}",
        Shape::Circle { radius } => "small circle r=${radius}",
        Shape::Rect { w, h } if w == h => "square ${w}x${h}",
        Shape::Rect { w, h } => "rect ${w}x${h}",
    }
}

// Nested enum pattern — Option<Option<Int>>
fn flatten_describe(opt: Option<Option<Int>>) -> Str {
    match opt {
        some(some(v)) if v > 0 => "positive: ${v}",
        some(some(v)) => "non-positive: ${v}",
        some(none) => "inner none",
        none => "outer none",
    }
}

fn main() {
    // or-patterns on directions
    print("east_h=${is_horizontal(Dir::East)}")
    print("north_h=${is_horizontal(Dir::North)}")
    print("south_v=${is_vertical(Dir::South)}")
    print("west_v=${is_vertical(Dir::West)}")

    // nested option matching
    print(both_or_none(some(3), some(7)))
    print(both_or_none(some(5), none))
    print(both_or_none(none, some(9)))
    print(both_or_none(none, none))

    // struct with guard
    print(rate(Score { name: "Alice", value: 95 }))
    print(rate(Score { name: "Bob", value: 75 }))
    print(rate(Score { name: "Charlie", value: 55 }))
    print(rate(Score { name: "Dave", value: 30 }))

    // enum named fields + guard
    print(describe_shape(Shape::Circle { radius: 20 }))
    print(describe_shape(Shape::Circle { radius: 5 }))
    print(describe_shape(Shape::Rect { w: 4, h: 4 }))
    print(describe_shape(Shape::Rect { w: 3, h: 7 }))

    // nested option with guard
    print(flatten_describe(some(some(42))))
    print(flatten_describe(some(some(-1))))
    print(flatten_describe(some(none)))
    print(flatten_describe(none))
}
