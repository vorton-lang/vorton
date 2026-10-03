// B-100 P1.3 adversarial: block expression locals drop timing.
// Block expressions used as values — locals inside the block must be
// dropped at block scope end, not leaked into the outer scope.

fn make_greeting(prefix: Str) -> Str {
    "${prefix}-hello"
}

fn format_pair(a: Int, b: Int) -> Str {
    "${a}+${b}=${a + b}"
}

fn consume(s: Str) -> Int {
    s.len()
}

fn main() {
    // Block as let-binding value — inner locals scoped to block
    let result = {
        let a = 10
        let b = 20
        a + b
    }
    print("block_let=${result}")

    // Block with string locals (heap-allocated, must drop at block end)
    let msg = {
        let greeting = make_greeting("hi")
        let name = "world"
        "${greeting} ${name}"
    }
    print("block_str=${msg}")

    // Nested blocks — inner block locals drop before outer block continues
    let nested = {
        let outer_val = 100
        let inner_result = {
            let x = 50
            let y = 25
            x + y
        }
        outer_val + inner_result
    }
    print("nested_block=${nested}")

    // Block as function argument (via let binding)
    let arg = {
        let a = 3
        let b = 7
        format_pair(a, b)
    }
    let len = consume(arg)
    print("block_arg_len=${len}")

    // Block returning a list (heap-allocated return value)
    let xs = {
        let mut items: List<Int> = []
        items.push(1)
        items.push(2)
        items.push(3)
        items
    }
    print("block_list=${xs.len()}")

    // Block in a loop — per-iteration block scope
    let mut total = 0
    for i in 0..4 {
        let contribution = {
            let base = i * 10
            let bonus = i
            base + bonus
        }
        total = total + contribution
    }
    print("block_loop=${total}")

    // Block with if-else inside
    let classified = {
        let val = 42
        if val > 50 {
            "big"
        } else {
            if val > 20 {
                "medium"
            } else {
                "small"
            }
        }
    }
    print("block_classify=${classified}")

    // Multiple sequential blocks — each block's locals are independent
    let b1 = { let x = 1; x + 10 }
    let b2 = { let x = 2; x + 20 }
    let b3 = { let x = 3; x + 30 }
    print("seq_blocks=${b1},${b2},${b3}")
}
