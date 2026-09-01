// Test: mut keyword in parameter position

fn double_in_place(mut x: Int) -> Int {
    x = x * 2
    x
}

fn accumulate(mut list: List<Int>, item: Int) {
    list.push(item)
}

fn main() {
    // mut param allows reassignment inside function
    let result = double_in_place(5)
    assert(result == 10, "mut param allows local reassignment")

    // mut list param — list is reference type, caller sees changes
    let mut items: List<Int> = []
    accumulate(items, 42)
    assert(items.len() == 1, "mut list param modifies caller list")
    assert(items.get(0).unwrap_or(-1) == 42, "mut list param has correct value")

    // passing a mut local into a mut param
    let mut n = 100
    let r2 = double_in_place(n)
    assert(r2 == 200, "mut local passed into mut param")

    print("let_mut_param: all tests passed")
}
