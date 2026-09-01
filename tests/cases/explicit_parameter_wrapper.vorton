fn connect(host: Str, port: Int, timeout: Int) -> Str {
    "${host}:${port.to_str()} (timeout=${timeout.to_str()})"
}

fn connect_localhost() -> Str {
    connect("localhost", 8080, 30)
}

fn main() {
    print(connect_localhost())
    print(connect("example", 443, 10))
}
