// Audit #258 negative: a Never arm is bottom and must not bind the fresh
// generic return type shared by later operation arms in the same handler.

effect Choice<T> {
    fn die() -> T
    fn live() -> T
}

fn poisoned() -> Int with {fail<Str>} {
    handle {
        Choice.live()
    } with {
        Choice.die() => fail.raise("unused"),
        Choice.live() => "text",
    }
}

fn main() {}
