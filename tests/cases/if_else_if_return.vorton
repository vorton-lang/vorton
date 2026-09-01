// Regression #111: if-else-if chain with nested return triggers emit_if_as_assign
fn process(items: List<Int>) -> Int {
    let y = if items.len() > 3 {
        for x in items {
            if x < 0 { return -1 }
        }
        100
    } else if items.len() > 1 {
        for x in items {
            if x < 0 { return -2 }
        }
        50
    } else {
        0
    }
    y + 1
}

fn main() {
    print(process([1, 2, 3, 4]))
    print(process([1, -5, 3, 4]))
    print(process([1, 2]))
    print(process([1, -3]))
    print(process([1]))
}
