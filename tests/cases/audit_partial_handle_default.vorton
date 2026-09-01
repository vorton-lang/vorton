// A custom handled effect installs one complete operation table, including
// operations that also have declaration defaults.
effect Storage {
    fn read_data(key: Str) -> Str
    fn log_access(key: Str) -> Unit {
        print("accessed: ${key}")
    }
}

fn get_data(key: Str) -> Str {
    Storage.log_access(key)
    Storage.read_data(key)
}

fn main() {
    let result = handle {
        get_data("config")
    } with {
        Storage.read_data(key) => "value_for_${key}",
        Storage.log_access(key) => { print("accessed: ${key}") },
    }
    assert(result == "value_for_config", "complete handler with default op")
    print("audit_partial_handle_default: all tests passed")
}
