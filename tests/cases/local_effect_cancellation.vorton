// Test: local variable mutation should not propagate mut effect

fn push_item(mut list: List<Int>) {
    list.push(1)
}

// bar should have NO mut effect — local is a local variable
fn bar() {
    let mut local: List<Int> = []
    push_item(local)
    print(local.len().to_str())
}

// baz SHOULD have mut effect — list is a parameter
fn baz(mut list: List<Int>) {
    push_item(list)
}

// Test chained local mutation — still no effect
fn chained() {
    let mut items: List<Int> = []
    push_item(items)
    push_item(items)
    print(items.len().to_str())
}

fn main() {
    bar()
    let mut items: List<Int> = []
    baz(items)
    print(items.len().to_str())
    chained()
}
