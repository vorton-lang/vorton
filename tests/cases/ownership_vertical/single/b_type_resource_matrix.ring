struct Resource {
    id: Int,
    payload: Str
}

impl Eq for Resource {
    fn eq(self, other: Resource) -> Bool { self.id == other.id }
}

impl Hash for Resource {
    fn hash(self) -> Int { self.id }
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Wrapper<T> {
    value: T
}

struct Sink<T> {
    value: T
}

enum Chain<T> {
    End,
    Link { value: T, tail: Option<Chain<T>> }
}

fn consume<T>(value: T) {
    let sink = Sink { value: value }
}

fn observe<T>(value: T) {}

fn main() {
    let direct = Resource { id: 1, payload: "direct" }
    consume(direct)
    observe(direct)

    let wrapped = Wrapper {
        value: Resource { id: 2, payload: "wrapper" }
    }
    consume(wrapped)
    observe(wrapped)

    let plain = Wrapper { value: 3 }
    consume(plain)
    observe(plain)
    assert(plain.value == 3,
        "Wrapper<Int> remains shareable through the same generic sink")

    let optional = some(Resource { id: 4, payload: "option" })
    consume(optional)
    observe(optional)

    let listed = [Resource { id: 5, payload: "list" }]
    consume(listed)
    observe(listed)

    let mapped = map_from([(6, Resource { id: 6, payload: "map" })])
    consume(mapped)
    observe(mapped)

    let mapped_key: Map<Resource, Int> = map_from([(
        Resource { id: 8, payload: "map-key" }, 8
    )])
    consume(mapped_key)
    observe(mapped_key)

    let setted = set_from([Resource { id: 7, payload: "set" }])
    consume(setted)
    observe(setted)

    let tupled = (Resource { id: 9, payload: "tuple" }, 9)
    consume(tupled)
    observe(tupled)

    let recursive: Chain<Resource> = Chain::Link {
        value: Resource { id: 10, payload: "recursive" },
        tail: some(Chain::End)
    }
    consume(recursive)
    observe(recursive)
}
