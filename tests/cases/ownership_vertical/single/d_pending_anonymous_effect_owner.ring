effect Trigger {
    fn read(value: Int) -> Int
}

effect InheritedStep {
    fn apply(value: Int) -> Int
}

fn make_wrapper(
    callback: fn(Int) -> Int
) -> fn(Int) -> Int {
    fn(value: Int) {
        callback(value) + 1
    }
}

fn handle_callback(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    handle {
        Trigger.read(value)
    } with {
        Trigger.read(current) => callback(current) + 2,
    }
}

fn increment(value: Int) -> Int { value + 1 }

fn inherited_step(value: Int) -> Int with {InheritedStep} {
    InheritedStep.apply(value)
}

fn main() {
    let pure_wrapper = make_wrapper(increment)
    let effect_wrapper = make_wrapper(inherited_step)
    let pure_factory = pure_wrapper(3)
    let effect_factory = handle {
        effect_wrapper(3)
    } with {
        InheritedStep.apply(value) => value + 5,
    }
    let pure_arm = handle_callback(increment, 3)
    let effect_arm = handle {
        handle_callback(inherited_step, 3)
    } with {
        InheritedStep.apply(value) => value + 5,
    }

    assert(pure_factory == 5 && effect_factory == 9 &&
        pure_arm == 6 && effect_arm == 10,
        "anonymous children inherit their finalized owner effect formal")
    print("D_PENDING_ANONYMOUS_OWNER_OK:${pure_factory}/${effect_factory}/${pure_arm}/${effect_arm}")
}
