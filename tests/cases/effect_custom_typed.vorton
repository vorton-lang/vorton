// Test: custom effects with type parameters
// effect Reader<T> should work — T is resolved correctly in op signatures

effect Reader<T> {
    fn ask() -> T
}

effect Writer<T> {
    fn tell(value: T) -> Unit
}

fn read_config() -> Str {
    Reader.ask()
}

fn read_int() -> Int {
    Reader.ask()
}

fn main() {
    // Test 1: Str-typed Reader effect
    let result = handle {
        let name = read_config()
        "hello ${name}"
    } with {
        Reader.ask() => "world",
    }
    assert(result == "hello world", "typed effect reader str")

    // Test 2: Int-typed Reader effect
    let result2 = handle {
        let x = read_int()
        x + 1
    } with {
        Reader.ask() => 42,
    }
    assert(result2 == 43, "typed effect reader int")

    // Test 3: Effect with typed parameter (Writer<Str>)
    let mut log: List<Str> = []
    handle {
        Writer.tell("alpha")
        Writer.tell("beta")
    } with {
        Writer.tell(v) => log.push(v),
    }
    assert(log.len() == 2, "writer collected 2 entries")

    // Test 4: Direct effect op call in handle body
    let result4 = handle {
        let x = Reader.ask()
        x * 2
    } with {
        Reader.ask() => 10,
    }
    assert(result4 == 20, "typed effect reader int multiply")

    print("effect_custom_typed: all tests passed")
}
