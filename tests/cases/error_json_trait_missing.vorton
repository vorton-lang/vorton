// A type without Json evidence must be rejected at a direct call site.
struct NotJson {
    value: Int
}

fn main() {
    print(json_stringify(NotJson { value: 1 }))
}
