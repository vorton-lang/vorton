// B-100 P1.1 parity: block expressions as values.
// Block expressions in let bindings, function arguments, nested blocks.
// Output must match golden .expected file.

fn show(x: Int) -> Str {
    "val=${x}"
}

fn main() {
    // block as let binding value
    let result = {
        let a = 10
        let b = 20
        a + b
    }
    print("block_let=${result}")                  // block_let=30

    // block with if-else as last expression
    let sign = {
        let n = -5
        if n > 0 { "positive" } else { "negative" }
    }
    print("block_if=${sign}")                     // block_if=negative

    // nested blocks
    let nested = {
        let outer = 10
        let inner = {
            let x = 20
            x + outer
        }
        inner * 2
    }
    print("nested=${nested}")                     // nested=60

    // block with let mut
    let counted = {
        let mut c = 0
        c = c + 1
        c = c + 1
        c = c + 1
        c
    }
    print("counted=${counted}")                   // counted=3

    // block as function argument (via binding to avoid RC verifier leak-temp)
    let product = {
        let a = 3
        let b = 4
        a * b
    }
    let msg = show(product)
    print("block_arg=${msg}")                     // block_arg=val=12

    // block returning string
    let greeting = {
        let name = "world"
        "hello ${name}"
    }
    print("block_str=${greeting}")                // block_str=hello world
}
