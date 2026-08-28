effect ImplStep {
    fn apply(value: Int) -> Int
}

struct RecursiveWalker {
    bias: Int
}

impl RecursiveWalker {
    fn self_walk(
        self,
        callback: fn(Int) -> Int,
        value: Int,
        remaining: Int
    ) -> Int {
        if remaining == 0 {
            value + self.bias
        } else {
            self.self_walk(callback, callback(value), remaining - 1)
        }
    }

    fn mutual_left(
        self,
        callback: fn(Int) -> Int,
        value: Int,
        remaining: Int
    ) -> Int {
        if remaining == 0 {
            value + self.bias
        } else {
            self.mutual_right(callback, callback(value), remaining - 1)
        }
    }

    fn mutual_right(
        self,
        callback: fn(Int) -> Int,
        value: Int,
        remaining: Int
    ) -> Int {
        if remaining == 0 {
            value + self.bias
        } else {
            self.mutual_left(callback, callback(value), remaining - 1)
        }
    }
}

fn increment(value: Int) -> Int { value + 1 }

fn impl_step(value: Int) -> Int with {ImplStep} {
    ImplStep.apply(value)
}

fn main() {
    let walker = RecursiveWalker { bias: 10 }
    let self_value = walker.self_walk(increment, 1, 2)
    let mutual_value = handle {
        walker.mutual_right(impl_step, 2, 3)
    } with {
        ImplStep.apply(value) => value + 2,
    }

    assert(self_value == 13 && mutual_value == 18,
        "impl self and mutual recursion publish exact callback effects")
    print("D_RECURSIVE_IMPL_METHODS_OK:${self_value}/${mutual_value}")
}
