// Custom effect mixed with fail — both handled in same handle block
effect Config {
    fn get_value(key: Str) -> Str
}

fn load_port() -> Int {
    let raw = Config.get_value("port")
    let port = parse_int(raw)
    match port {
        some(n) => n,
        none => { fail.raise("bad port"); 0 }
    }
}

fn main() {
    // Case 1: config returns valid port, no fail
    let r1 = handle {
        load_port()
    } with {
        Config.get_value(key) => "8080",
        fail.raise(e) => -1,
    }
    assert(r1 == 8080, "valid port")

    // Case 2: config returns unparseable value, fail fires
    let r2 = handle {
        load_port()
    } with {
        Config.get_value(key) => "not_a_number",
        fail.raise(e) => -1,
    }
    assert(r2 == -1, "fail on bad port")

    print("effect_custom_and_fail: all tests passed")
}
