// All function parameters are required; an omitted argument is ordinary E0301.

fn connect(host: Str, port: Int, timeout: Int) -> Str {
    "${host}:${port.to_str()}"
}

fn main() {
    print(connect())
}
