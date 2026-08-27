struct Resource {
    id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

struct OwnedSink {
    value: Resource
}

fn borrow_id(value: Resource) -> Int { value.id }
fn borrow_plus_one(value: Resource) -> Int { value.id + 1 }

fn consume_same_signature(value: Resource) -> Int {
    let sink = OwnedSink { value: value }
    sink.value.id
}

fn choose_reader(first: Bool) -> fn(Resource) -> Int {
    if first {
        return borrow_id
    }
    return borrow_plus_one
    // This Return is preserved in frozen Flow topology but is structurally
    // unreachable. Its owning callable must not widen the reachable result.
    return consume_same_signature
}

fn main() {
    let value = Resource { id: 41, payload: "reachable" }
    let reader = choose_reader(true)
    assert(reader(value) == 41, "reachable callable result")
    assert(value.id == 41,
        "dead owning callable candidate must not consume the live owner")
    let consumed = consume_same_signature(value)
    assert(consumed == 41, "final exact owning consumer")
    print("C_DEAD_CALLABLE_OK")
}
