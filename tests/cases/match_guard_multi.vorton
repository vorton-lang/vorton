// Regression C3: same variant with multiple arms + guards
enum Shape { circle(Int), rect(Int, Int) }

fn classify(s: Shape) -> Str {
    match s {
        circle(r) if r > 5 => "big circle",
        circle(r) => "small circle",
        rect(w, h) if w == h => "square",
        rect(w, h) => "rectangle",
    }
}

fn main() {
    print(classify(circle(10)))
    print(classify(circle(3)))
    print(classify(rect(5, 5)))
    print(classify(rect(3, 7)))
}
