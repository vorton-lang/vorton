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

fn make_double_wrapper(
    callback: fn(Int) -> Int
) -> fn(Int) -> fn(Int) -> Int {
    fn(delta: Int) -> fn(Int) -> Int {
        fn(value: Int) {
            callback(value) + delta
        }
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

fn inherited_step(value: Int) -> Int with {InheritedStep} {
    InheritedStep.apply(value)
}

fn hash_with_step<T: Hash>(value: T) -> Int with {InheritedStep} {
    InheritedStep.apply(value.hash())
}

fn call_bounded<T: Hash>(
    callback: fn(T) -> Int,
    value: T
) -> Int {
    callback(value)
}

fn main() {
    // Creation is pure. The first call borrows the handler installed later.
    let outside = make_wrapper(inherited_step)
    let outside_inside = handle {
        outside(1)
    } with {
        InheritedStep.apply(value) => value + 10,
    }

    // Creation under +100 must not retain that evidence after escape.
    let escaped = handle {
        make_wrapper(inherited_step)
    } with {
        InheritedStep.apply(value) => value + 100,
    }
    let rebound = handle {
        escaped(1)
    } with {
        InheritedStep.apply(value) => value + 20,
    }

    // Neither factory layer captures its creation handler. The innermost
    // dynamic handler wins, then the enclosing handler is restored.
    let double = handle {
        make_double_wrapper(inherited_step)
    } with {
        InheritedStep.apply(value) => value + 100,
    }
    let leaf = handle {
        double(2)
    } with {
        InheritedStep.apply(value) => value + 200,
    }
    let nested = handle {
        let inner = handle {
            leaf(3)
        } with {
            InheritedStep.apply(value) => value + 30,
        }
        let outer_again = leaf(4)
        inner * 1000 + outer_again
    } with {
        InheritedStep.apply(value) => value + 300,
    }

    // A runtime handler arm is internal: its callback tail receives the
    // surrounding dynamic evidence while the Trigger arm is executing.
    let arm = handle {
        handle_callback(inherited_step, 3)
    } with {
        InheritedStep.apply(value) => value + 40,
    }

    // Indirect generic dispatch carries env, the Hash dictionary, then the
    // current handled evidence without swapping either hidden argument.
    let ordered = handle {
        call_bounded(hash_with_step, 7)
    } with {
        InheritedStep.apply(value) => 77,
    }

    assert(outside_inside == 12 && rebound == 22 &&
        nested == 35306 && arm == 45 && ordered == 77,
        "ordinary closures use current dynamic handled evidence")
    print("D_DYNAMIC_EVIDENCE_OK:${outside_inside}/${rebound}/${nested}/${arm}/${ordered}")
}
