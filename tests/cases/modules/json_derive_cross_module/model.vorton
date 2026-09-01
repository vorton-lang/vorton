@derive(Json)
pub struct Payload<T> {
    pub name: Str,
    pub values: List<T>
}

@derive(Json)
pub enum ResultShape {
    Ready { code: Int },
    Waiting
}
