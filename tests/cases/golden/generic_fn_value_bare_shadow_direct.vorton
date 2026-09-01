fn increment(value: Int) -> Int with {} {
    value + 1
}

fn add_two(value: Int) -> Int with {} {
    value + 2
}

fn main() {
    print("generic fn value bare shadow direct: all ok")
    let print = increment
    let Cell = add_two
    let ptr_from_addr = increment
    assert(print(40) == 41,
        "bare local print direct call wins over runtime print")
    assert(Cell(40) == 42,
        "bare local Cell direct call wins over builtin Cell")
    assert(ptr_from_addr(40) == 41,
        "bare local ptr_from_addr direct call wins over builtin special")
}
