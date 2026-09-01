// The derive diagnostic must point at the opt-in below, not span_zero().
// Keep the attribute off line 1 so the LLM regression detects that fallback.

@derive(Json)
struct JsonFieldMissing {
    callback: fn(Int) -> Int
}

fn main() {
    let value = JsonFieldMissing { callback: fn(x) { x + 1 } }
    print(json_stringify(value))
}
