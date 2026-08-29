effect ModuleStep {
    fn apply(value: Int) -> Int
}

mod recursive_module {
    pub fn left(
        callback: fn(Int) -> Int,
        value: Int,
        remaining: Int
    ) -> Int {
        if remaining == 0 {
            value
        } else {
            self::right(callback, callback(value), remaining - 1)
        }
    }

    fn right(
        callback: fn(Int) -> Int,
        value: Int,
        remaining: Int
    ) -> Int {
        if remaining == 0 {
            value
        } else {
            self::left(callback, callback(value), remaining - 1)
        }
    }
}

fn increment(value: Int) -> Int with {} { value + 1 }

fn module_step(value: Int) -> Int with {ModuleStep} {
    ModuleStep.apply(value)
}

fn main() {
    let pure = recursive_module::left(increment, 0, 2)
    let handled = handle {
        recursive_module::left(module_step, 1, 3)
    } with {
        ModuleStep.apply(value) => value + 3,
    }

    assert(pure == 2 && handled == 10,
        "inline-module peers close one recursive effect group")
    print("D_RECURSIVE_INLINE_MODULE_OK:${pure}/${handled}")
}
