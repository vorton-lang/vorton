struct Resource {
    id: Int
}

impl Drop for Resource {
    fn drop(self) {}
}

fn extract(value: Option<Resource>) -> Resource {
    match value {
        some(item) => item,
        none => Resource { id: 0 }
    }
}

fn observe(value: Option<Resource>) -> Int {
    match value {
        some(item) => item.id,
        none => 0
    }
}

fn main() {
    let source = some(Resource { id: 7 })
    let moved = extract(source)
    let reused = observe(source)
    print("${moved.id}:${reused}")
}
