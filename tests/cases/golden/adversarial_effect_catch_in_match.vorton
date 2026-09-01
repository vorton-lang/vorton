// B-100 P1.3: adversarial — catch inside match arms.
// Tests that catch blocks work correctly when nested inside match
// arm expressions, where the match scrutinee and catch interact.

enum Shape { Circle { r: Int }, Square { s: Int }, Unknown }
enum E { BadShape }

fn area(shape: Shape) -> Int with {fail<E>} {
    match shape {
        Shape::Circle { r } => r * r * 3
        Shape::Square { s } => s * s
        Shape::Unknown => fail.raise(E::BadShape)
    }
}

fn main() {
    // Test 1: catch inside each match arm
    let shapes = [Shape::Circle { r: 5 }, Shape::Square { s: 4 }, Shape::Unknown]
    for shape in shapes {
        let desc = match shape {
            Shape::Circle { r } => {
                let a = area(shape) catch { _ => -1 }
                "circle:${a.to_str()}"
            }
            Shape::Square { s } => {
                let a = area(shape) catch { _ => -1 }
                "square:${a.to_str()}"
            }
            Shape::Unknown => {
                let a = area(shape) catch { _ => -1 }
                "unknown:${a.to_str()}"
            }
        }
        print(desc)
    }

    // Test 2: catch wrapping a match that may fail
    let r2 = {
        let s = Shape::Unknown
        area(s)
    } catch { _ => -99 }
    print("T2: ${r2.to_str()}")

    // Test 3: match on catch result
    let r3 = area(Shape::Unknown) catch { _ => 0 }
    let label = match r3 {
        0 => "caught"
        _ => "ok"
    }
    print("T3: ${label}")

    print("adversarial_effect_catch_in_match: done")
}
