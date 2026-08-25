// Test: delegate forwarding correctly passes effect evidence

trait Loggable {
    fn log_self(self) -> Str with {console}
}

struct Inner { name: Str }

impl Loggable for Inner {
    fn log_self(self) -> Str with {console} {
        print("logging: ${self.name}")
        self.name
    }
}

struct Wrapper { inner: Inner }

impl Wrapper {
    delegate inner: Loggable
}

fn main() {
    let w = Wrapper { inner: Inner { name: "test" } }
    let result = w.log_self()
    assert(result == "test", "delegate with effects")
    print("delegate with effects: ok")
}
