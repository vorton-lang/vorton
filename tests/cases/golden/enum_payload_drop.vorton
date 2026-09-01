// #157 regression: a fresh payload-enum let binding in a loop, matched then
// discarded (match only projects scalar payload, does not consume the outer
// shell).  The perceus scope-end-drop must reclaim the enum each iteration.
// verify_rc (self-verify gate) proves the Drop is emitted at the HIR level.

enum Color {
    Red,
    Blue { shade: Int },
    Green { r: Int, g: Int },
}

fn main() {
    // Case 1: single-field payload-enum, match projects scalar
    for i in 0..5 {
        let c = Color::Blue { shade: i }
        match c {
            Color::Blue { shade } => print("${shade}"),
            Color::Red => print("red"),
            Color::Green { r, g } => print("green"),
        }
    }

    // Case 2: multi-field payload-enum
    for i in 0..3 {
        let col = Color::Green { r: i, g: i + 10 }
        match col {
            Color::Green { r, g } => print("${r},${g}"),
            _ => print("other"),
        }
    }

    // Case 3: match result bound to a let (the enum is still scope-end-dropped)
    for i in 0..3 {
        let c = Color::Blue { shade: i }
        let doubled = match c {
            Color::Blue { shade } => shade * 2,
            Color::Red => 0,
            Color::Green { r, g } => r + g,
        }
        print("d=${doubled}")
    }
}
