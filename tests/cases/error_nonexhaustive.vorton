// TestGap T1: Non-exhaustive match should be rejected
enum Shape { circle(Float), rect(Float, Float) }

fn describe(s: Shape) -> Str {
    match s {
        circle(r) => "circle",
    }
}

fn main() {
    print(describe(circle(1.0)))
}
