struct Point { x: Int, y: Int }

fn describe(p: Point) -> Str {
    match p {
        Point { x: 0, y: 0 } => "origin",
        Point { x: 0, y } => "y-axis at ${y.to_str()}",
        Point { x, y: 0 } => "x-axis at ${x.to_str()}",
        Point { x, y } => "(${x.to_str()}, ${y.to_str()})",
    }
}

fn main() {
    assert(describe(Point { x: 0, y: 0 }) == "origin", "origin")
    assert(describe(Point { x: 0, y: 5 }) == "y-axis at 5", "y-axis")
    assert(describe(Point { x: 3, y: 0 }) == "x-axis at 3", "x-axis")
    assert(describe(Point { x: 1, y: 2 }) == "(1, 2)", "general")
    print("struct_match_pattern: all tests passed")
}
