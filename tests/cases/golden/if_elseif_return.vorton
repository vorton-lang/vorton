// B-100 P1.1 parity: if/else-if/return — if-else-if chains as expressions,
// early return, return inside expression blocks.

fn grade(score: Int) -> Str {
    if score >= 90 {
        "A"
    } else if score >= 80 {
        "B"
    } else if score >= 70 {
        "C"
    } else {
        "D"
    }
}

fn abs(x: Int) -> Int {
    if x < 0 { -x } else { x }
}

fn find_positive(xs: List<Int>) -> Int {
    for x in xs {
        if x > 0 { return x }
    }
    -1
}

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

fn return_in_block() -> Int {
    let x = {
        if true {
            return 42
        }
        0
    }
    x
}

fn no_return_block() -> Int {
    let a = {
        let tmp = 10
        tmp + 5
    }
    a
}

fn main() {
    // if-else-if chain as expression
    print("grade95=${grade(95)}")
    print("grade85=${grade(85)}")
    print("grade75=${grade(75)}")
    print("grade60=${grade(60)}")

    // Simple if-else expression
    print("abs5=${abs(-5)}")
    print("abs3=${abs(3)}")

    // Early return from function
    print("pos=${find_positive([-3, -1, 0, 5, 2])}")
    print("neg=${find_positive([-1, -2, -3])}")

    // if-else-if with return inside branches
    print("p1=${process([1, 2, 3, 4])}")
    print("p2=${process([1, -5, 3, 4])}")
    print("p3=${process([1, 2])}")
    print("p4=${process([1, -3])}")
    print("p5=${process([1])}")

    // Return inside expression block
    print("ret_block=${return_in_block()}")
    print("no_ret=${no_return_block()}")
}
