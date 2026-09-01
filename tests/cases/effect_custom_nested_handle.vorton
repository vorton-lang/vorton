// Nested handlers for same custom effect — inner shadows outer
effect Config {
    fn get(key: Str) -> Str
}

fn read_config() -> Str {
    Config.get("mode")
}

fn main() {
    let result = handle {
        let outer_mode = read_config()
        let inner_mode = handle {
            read_config()
        } with {
            Config.get(k) => "test",
        }
        "${outer_mode}-${inner_mode}"
    } with {
        Config.get(k) => "prod",
    }
    assert(result == "prod-test", "inner handler shadows outer")
    print("effect_custom_nested_handle: all tests passed")
}
