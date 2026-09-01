// Block expressions containing while, for..in, if-let, let-destructure, break, continue
fn main() {
    // while in block expr
    let sum_while = {
        let mut sum = 0
        let mut i = 0
        while i < 5 {
            sum = sum + i
            i = i + 1
        }
        sum
    }
    assert(sum_while == 10, "while in block expr")

    // for..in in block expr
    let sum_for = {
        let mut total = 0
        for i in 0..5 {
            total = total + i
        }
        total
    }
    assert(sum_for == 10, "for..in in block expr")

    // let destructure in block expr
    let destructure_sum = {
        let (a, b) = (10, 20)
        a + b
    }
    assert(destructure_sum == 30, "let destructure in block expr")

    // if-let in block expr
    let if_let_result = {
        let opt = some(42)
        let mut result = 0
        if let some(v) = opt {
            result = v
        }
        result
    }
    assert(if_let_result == 42, "if-let in block expr")

    // break/continue in loop inside block expr
    let break_result = {
        let mut found = -1
        for i in 0..10 {
            if i == 7 {
                found = i
                break
            }
        }
        found
    }
    assert(break_result == 7, "break in loop inside block expr")

    print("all block expr tests passed")
}
