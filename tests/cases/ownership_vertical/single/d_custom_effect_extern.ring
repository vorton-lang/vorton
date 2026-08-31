effect LocalClock {
    fn now() -> Int
}

extern fn foreign_now() -> Int with {LocalClock}

fn main() {}
