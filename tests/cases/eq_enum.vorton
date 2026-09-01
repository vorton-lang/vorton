enum Color { Red, Green, Blue }
enum Shape { Circle(Float), Rect(Float, Float) }

fn main() {
    assert(Color::Red == Color::Red, "same unit variant")
    assert(Color::Red != Color::Green, "different unit variants")
    assert(Circle(3.14) == Circle(3.14), "same fields")
    assert(Circle(3.14) != Circle(2.0), "different fields")
    assert(Circle(1.0) != Rect(1.0, 1.0), "different variants")
    print("eq_enum: all tests passed")
}
