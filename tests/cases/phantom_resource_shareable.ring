struct Resource {
    id: Int
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Phantom<T> {
    marker: Int
}

struct Sink<T> {
    value: T
}

fn own(value: Phantom<Resource>) -> Unit {
    let sink = Sink { value }
}

fn main() {
    let phantom: Phantom<Resource> = Phantom { marker: 17 }
    own(phantom)
    assert(phantom.marker == 17,
        "phantom generic must not inherit Resource ownership")
    print("PHANTOM_RESOURCE_SHAREABLE_OK")
}
