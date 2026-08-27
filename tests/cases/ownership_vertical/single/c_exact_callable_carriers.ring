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

struct Readers {
    left: fn(Resource) -> Int,
    right: fn(Resource) -> Int
}

enum ReaderChoice {
    Read(fn(Resource) -> Int),
    Alternate(fn(Resource) -> Int)
}

fn borrow_id(value: Resource) -> Int { value.id }
fn borrow_plus_three(value: Resource) -> Int { value.id + 3 }
fn borrow_plus_four(value: Resource) -> Int { value.id + 4 }
fn borrow_plus_five(value: Resource) -> Int { value.id + 5 }

// Same surface function type, but a different ownership mode. It is never a
// candidate at the borrowing call sites below and therefore must not widen
// their callable set merely because the signatures match.
fn consume_same_signature(value: Resource) -> Int {
    let sink = OwnedSink { value: value }
    sink.value.id
}

fn call_exact(callback: fn(Resource) -> Int, value: Resource) -> Int {
    callback(value)
}

fn make_reader(offset: Int) -> fn(Resource) -> Int {
    fn(value: Resource) -> Int { value.id + offset }
}

fn make_captured_str_reader(label: Str) -> fn() -> Int {
    fn() -> Int { label.len() }
}

fn main() {
    let resource = Resource { id: 10, payload: "exact" }
    let mut score = call_exact(borrow_id, resource)

    let local = fn(value: Resource) -> Int { value.id + 1 }
    score = score + call_exact(local, resource)

    let factory_reader = make_reader(2)
    score = score + call_exact(factory_reader, resource)

    let captured_reader = make_captured_str_reader("xy")
    score = score + captured_reader()
    score = score + captured_reader()

    let readers = Readers {
        left: borrow_id,
        right: borrow_plus_three
    }
    let left = readers.left
    let right = readers.right
    score = score + call_exact(left, resource)
    score = score + call_exact(right, resource)

    let tuple_readers = (borrow_id, borrow_plus_four)
    let tuple_left = tuple_readers.0
    let tuple_right = tuple_readers.1
    score = score + call_exact(tuple_left, resource)
    score = score + call_exact(tuple_right, resource)

    let choice = ReaderChoice::Read(borrow_plus_five)
    score = score + match choice {
        ReaderChoice::Read(callback) => call_exact(callback, resource),
        ReaderChoice::Alternate(callback) => call_exact(callback, resource)
    }

    assert(resource.id == 10,
        "named/lambda/factory/field/tuple/enum borrowing kept the owner live")
    score = score + consume_same_signature(resource)
    assert(score == 109, "exact callable carrier result")
    print("C_EXACT_CALLABLE_OK:${score}")
}
