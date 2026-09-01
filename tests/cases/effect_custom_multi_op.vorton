// Test: custom effect with multiple operations (tail-resumptive semantics)

effect Config {
    fn get_name() -> Str
    fn get_count() -> Int
}

fn describe() -> Str {
    let name = Config.get_name()
    let count = Config.get_count()
    "${name}:${count}"
}

fn main() {
    let result = handle {
        describe()
    } with {
        Config.get_name() => "app",
        Config.get_count() => 42,
    }
    assert(result == "app:42", "custom multi-op")

    print("effect_custom_multi_op: all tests passed")
}
