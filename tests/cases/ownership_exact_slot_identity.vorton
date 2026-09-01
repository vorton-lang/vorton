fn raise_number() -> Int with {fail<Int>} {
    fail.raise(23)
}

fn early_shadow(flag: Bool) -> Int {
    let value = 50
    if flag {
        let value = 51
        return value
    }
    value
}

fn main() {
    let shadowed = 11
    {
        let shadowed = 12
        let read_shadowed = fn() -> Int { shadowed }
        print(read_shadowed())
    }
    print(shadowed)

    let then_shadowed = 18
    if true {
        let then_shadowed = 19
        print(then_shadowed)
    } else {
        print(-1)
    }
    print(then_shadowed)

    let else_shadowed = 20
    if false {
        print(-1)
    } else {
        let else_shadowed = 21
        print(else_shadowed)
    }
    print(else_shadowed)

    let selected = 13
    match some(14) {
        some(selected) => {
            let read_selected = fn() -> Int { selected }
            print(read_selected())
        },
        none => {}
    }
    print(selected)

    let conditional = 15
    if let some(conditional) = some(16) {
        let read_conditional = fn() -> Int { conditional }
        print(read_conditional())
    }
    print(conditional)

    let caught = 17
    let recovered = raise_number() catch {
        caught => {
            let read_caught = fn() -> Int { caught }
            read_caught()
        }
    }
    print(recovered)
    print(caught)

    let tupled = 30
    let (tupled, other) = (31, 32)
    print(tupled)
    print(other)

    let mut scalar = 1
    scalar = 2
    print(scalar)

    print(early_shadow(true))
    print(early_shadow(false))

    let loop_shadowed = 40
    while true {
        let loop_shadowed = 41
        print(loop_shadowed)
        break
    }
    print(loop_shadowed)
}
