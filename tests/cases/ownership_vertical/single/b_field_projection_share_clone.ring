struct TextPair {
    left: Str,
    right: Str
}

struct TextSink {
    value: Str
}

fn consume_text(value: Str) -> Int {
    let sink = TextSink { value: value }
    sink.value.len()
}

fn main() {
    let pair = TextPair { left: "left", right: "right" }
    assert(consume_text(pair.left) == 4,
        "Own shareable field projects then clones the result")
    assert(pair.left == "left" && pair.right == "right",
        "field Own never consumes the aggregate base or sibling")
    print("B_FIELD_PROJECT_CLONE_OK")
}
