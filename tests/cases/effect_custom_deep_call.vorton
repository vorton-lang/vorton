// Custom effect through multiple layers of function calls
effect Env {
    fn read_env(key: Str) -> Str
}

fn get_host() -> Str {
    Env.read_env("HOST")
}

fn get_port() -> Str {
    Env.read_env("PORT")
}

fn build_url() -> Str {
    let host = get_host()
    let port = get_port()
    "${host}:${port}"
}

fn connect() -> Str {
    let url = build_url()
    "connected to ${url}"
}

fn main() {
    let result = handle {
        connect()
    } with {
        Env.read_env(key) => {
            if key == "HOST" { "localhost" }
            else { "3000" }
        },
    }
    assert(result == "connected to localhost:3000", "deep call chain")
    print("effect_custom_deep_call: all tests passed")
}
