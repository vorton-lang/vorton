// Specializing json_stringify as a first-class function must retain its Json bound.
struct NotJsonFnValue {
    value: Int
}

fn apply_json(
    f: fn(NotJsonFnValue) -> Str,
    value: NotJsonFnValue
) -> Str {
    f(value)
}

fn main() {
    print(apply_json(json_stringify, NotJsonFnValue { value: 1 }))
}
