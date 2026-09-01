// Cross-owner compatibility leaves follow target use order, while both exact
// aliases remain independently addressable.
use other::{Second as Right}
use defs::{First as Left}

fn left_score(value: Left) -> Int {
    match value {
        Left::Call(number) => number,
    }
}

fn right_score(value: Right) -> Int {
    match value {
        Right::Call(number) => number,
    }
}

fn main() {
    print(left_score(Call(5)))
    print(left_score(Left::Call(7)))
    print(right_score(Right::Call(11)))
}
