use forward::{ForwardResource}

struct ResourceSink {
    value: ForwardResource
}

pub fn take_resource(value: ForwardResource) -> Int {
    let sink = ResourceSink { value: value }
    sink.value.id
}

pub fn keep_provider() -> Int { 0 }
