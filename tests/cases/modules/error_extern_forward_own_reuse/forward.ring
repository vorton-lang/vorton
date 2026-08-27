pub struct ForwardResource {
    id: Int,
    payload: Str
}

impl Drop for ForwardResource {
    fn drop(self) {}
}

extern fn take_resource(value: ForwardResource) -> Int

pub fn invalid_reuse() -> Int {
    let value = ForwardResource { id: 9, payload: "owned" }
    let result = take_resource(value)
    result + value.id
}
