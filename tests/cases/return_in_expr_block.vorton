// Regression test: return in expression-position blocks should return
// from the outer function, not from a generated IIFE.

fn test_return_in_let() -> Int {
    let x = {
        if true {
            return 42
        }
        0
    }
    x
}

fn test_return_in_nested_block() -> Int {
    let a = {
        let flag = true
        if flag {
            return 99
        }
        10
    }
    a
}

fn test_no_return_block_unchanged() -> Int {
    // Block without return should still work (IIFE path)
    let a = {
        let tmp = 10
        tmp + 5
    }
    a
}

fn test_return_in_block_with_stmts() -> Int {
    let x = {
        let a = 1
        let b = 2
        if a + b == 3 {
            return 77
        }
        a + b
    }
    x
}

fn main() {
    assert(test_return_in_let() == 42, "return in let block")
    assert(test_return_in_nested_block() == 99, "return in nested block")
    assert(test_no_return_block_unchanged() == 15, "block without return unchanged")
    assert(test_return_in_block_with_stmts() == 77, "return in block with stmts")
    print("return_in_expr_block: ok")
}
