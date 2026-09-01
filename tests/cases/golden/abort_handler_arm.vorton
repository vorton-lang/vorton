// Audit #251 regression: fail.raise abort handlers execute their arm body
// exactly once after the current catch frame and handler evidence are inactive.
// The handwritten expected file is the semantic oracle for both backends.

effect Transform {
    fn apply(value: Int) -> Int
}

effect Fallback {
    fn value() -> Int { 30 }
}

fn raise_text(message: Str) -> Int with {fail<Str>} {
    fail.raise(message)
}

fn raise_number(value: Int) -> Int with {fail<Int>} {
    fail.raise(value)
}

fn raise_owned_text(message: Str) -> Str with {fail<Str>} {
    fail.raise(message)
}

// The normal result remains the polymorphic T even though the abort arm is
// Never. This pins the #180 bottom-poisoning guard for abort-result joining.
fn generic_passthrough<T>(value: T, should_fail: Bool) -> T with {fail<Str>} {
    handle {
        if should_fail { fail.raise("generic") }
        value
    } with {
        fail.raise(message: Str) => fail.raise("propagated:${message}"),
    }
}

fn main() {
    let shadow = "outer-shadow"
    let immutable_bias = 7
    let words: List<Str> = ["alpha", "beta"]
    let mut arm_hits = 0

    // Non-identity mapping, payload binding, side effects exactly once, outer
    // immutable/List captures, mutable capture, and same-name binder isolation.
    let mapped = handle {
        raise_text("boom")
    } with {
        fail.raise(shadow: Str) => {
            arm_hits = arm_hits + 1
            print("mapped-arm:${shadow}:${immutable_bias}:${words.len()}")
            shadow.len() + immutable_bias + words.len()
        },
    }
    let normal = handle {
        41
    } with {
        fail.raise(unused: Str) => {
            arm_hits = arm_hits + 100
            0
        },
    }
    assert(mapped == 13, "abort arm maps payload")
    assert(arm_hits == 1, "abort arm executes exactly once and not on normal path")
    assert(shadow == "outer-shadow", "abort parameter does not leak past handle")
    print("mapped=${mapped} hits=${arm_hits} normal=${normal} shadow=${shadow}")

    // The abort arm may produce a fresh owned heap value rather than returning
    // the tagged payload. It must escape the catch arm and survive the backend
    // merge/Perceus ownership path.
    let owned = handle {
        raise_owned_text("heap")
    } with {
        fail.raise(message: Str) => "owned:${message}",
    }
    assert(owned == "owned:heap", "fresh owned abort-arm result escapes")
    assert(owned.len() == 10, "fresh owned abort-arm result remains live")
    print("owned=${owned}")

    // A directly raised body has type Never; the recovering abort arm determines
    // the handle's Int result instead of leaving HExpr.ty stuck at Never.
    let bottom_recovered = handle {
        fail.raise("never-body")
    } with {
        fail.raise(message: Str) => message.len(),
    }
    assert(bottom_recovered == 10, "Never body joins to abort arm result")
    print("bottom=${bottom_recovered}")

    // Nested abort: the inner arm handles the payload once; the outer arm is
    // not entered when the inner arm completes normally.
    let mut nested_hits = 0
    let nested = handle {
        handle {
            raise_text("inner")
        } with {
            fail.raise(inner_payload: Str) => {
                nested_hits = nested_hits + 1
                inner_payload.len() + 20
            },
        }
    } with {
        fail.raise(outer_payload: Str) => {
            nested_hits = nested_hits + 100
            0 - 1
        },
    }
    assert(nested == 25, "inner abort arm result")
    assert(nested_hits == 1, "outer abort arm stays inactive")
    print("nested=${nested} nested_hits=${nested_hits}")

    // Re-raise from an abort arm must escape to the already-active outer frame,
    // never jump back into the current handle.
    let reraised = handle {
        handle {
            raise_text("first")
        } with {
            fail.raise(inner_message: Str) => {
                arm_hits = arm_hits + 1
                fail.raise("again:${inner_message}")
            },
        }
    } with {
        fail.raise(outer_message: Str) => {
            arm_hits = arm_hits + 1
            print("outer-rethrow:${outer_message}")
            outer_message.len()
        },
    }
    assert(reraised == 11, "outer handler maps reraised payload")
    assert(arm_hits == 3, "inner and outer reraised arms each run once")
    print("reraised=${reraised} hits=${arm_hits}")

    // The inner handle also installs Transform evidence. Its abort arm must run
    // after that evidence is dropped/restored, so Transform.apply dispatches to
    // the outer handler (+10), not the inactive inner handler (+1000).
    let routed = handle {
        handle {
            raise_text("route")
        } with {
            Transform.apply(value) => value + 1000,
            fail.raise(message: Str) => Transform.apply(message.len()),
        }
    } with {
        Transform.apply(value) => value + 10,
    }
    assert(routed == 15, "ordinary effect in abort arm escapes current handle")
    print("routed=${routed}")

    // There is no outer lexical Fallback evidence mapping. Restoring the outer
    // state must REMOVE the dropped inner mapping, allowing default evidence
    // lookup instead of dispatching through the inactive override.
    let default_routed = handle {
        raise_text("fallback")
    } with {
        Fallback.value() => 900,
        fail.raise(message: Str) => Fallback.value() + message.len(),
    }
    assert(default_routed == 38, "absent outer evidence mapping is restored")
    print("fallback=${default_routed}")

    // Polymorphic normal results survive a Never abort arm, while the arm's
    // re-raised fail remains visible to and catchable by the outer handler.
    let generic_int = generic_passthrough(9, false) catch { _ => -1 }
    let generic_str = generic_passthrough("ok", false) catch { _ => "fallback" }
    let generic_failed = handle {
        generic_passthrough(1, true)
    } with {
        fail.raise(message: Str) => {
            print("generic-rethrow:${message}")
            0 - 1
        },
    }
    assert(generic_int == 9, "generic Int result is not poisoned by Never")
    assert(generic_str == "ok", "generic Str result is not poisoned by Never")
    assert(generic_failed == -1, "generic reraised fail reaches outer handler")
    print("generic=${generic_int}/${generic_str}/${generic_failed}")

    // Repeated aborts with a non-abort evidence object exercise catch-path
    // evidence/closure cleanup. Tagged Int payloads avoid unrelated unwind RC.
    let mut checksum = 0
    for i in 0..25 {
        let value = handle {
            raise_number(i)
        } with {
            Transform.apply(n) => n + 1000,
            // No annotation: the concrete body fail<Int> row constrains n.
            fail.raise(n) => n + 1,
        }
        checksum = checksum + value
    }
    assert(checksum == 325, "abort catch cleanup loop")
    print("cleanup=${checksum}")
    print("abort_handler_arm: done")
}
