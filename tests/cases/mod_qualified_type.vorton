// Regression test for #55: qualified type syntax in type annotations

mod geo {
    pub struct Point {
        pub x: Int,
        pub y: Int,
    }
}

fn make_point(x: Int, y: Int) -> geo::Point {
    geo::Point { x: x, y: y }
}

fn show_point(p: geo::Point) -> Str {
    "${p.x.to_str()},${p.y.to_str()}"
}

fn main() {
    let p = make_point(3, 4)
    print(show_point(p))
}
