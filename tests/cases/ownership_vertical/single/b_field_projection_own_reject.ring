struct Resource {
    id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Pair {
    a: Resource,
    b: Resource
}

struct ResourceSink {
    value: Resource
}

fn consume_resource(value: Resource) -> Int {
    let sink = ResourceSink { value: value }
    sink.value.id
}

fn main() {
    let pair = Pair {
        a: Resource { id: 1, payload: "a" },
        b: Resource { id: 2, payload: "b" }
    }
    // Ring 0.1 rejects this exact-place partial move. The Planner must not
    // turn it into a whole-aggregate Take that also consumes pair.b.
    consume_resource(pair.a)
    print(pair.a.id + pair.b.id)
}
