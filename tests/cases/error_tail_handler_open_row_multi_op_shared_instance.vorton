// Audit #258 negative: a body with only an unknown open callback tail does not
// constrain the handler instance, but the handler's own operation arms still
// share one generic effect instance.

effect Pair<T> {
    fn first() -> T
    fn second() -> T
}

fn incoherent_open_handler(callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        Pair.first() => 1,
        Pair.second() => "text",
    }
}

fn main() {}
