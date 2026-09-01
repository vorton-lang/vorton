// Handler arms are runtime closures. Mutable captures must share their cell
// with the enclosing scope, across multiple arms and nested handler scopes.
effect Accumulate {
    fn add(delta: Int) -> Unit
    fn add_twice(delta: Int) -> Unit
}

effect NestedBump {
    fn bump(delta: Int) -> Unit
}

effect OuterDispatch {
    fn run(value: Int) -> Unit
}

effect InnerDispatch {
    fn add(value: Int) -> Unit
    fn local_only(value: Int) -> Unit
    fn shadow(value: Set<Int>) -> Unit
}

effect DeepDispatch {
    fn finish(value: Int) -> Unit
}

extern type ForeignShadow

effect ExternShadow {
    fn inspect(value: ForeignShadow) -> Unit
}

fn run_accumulate() {
    Accumulate.add(1)
    Accumulate.add_twice(2)
    Accumulate.add(3)
}

// Compile-only classifier probe: the function cannot be called without a real
// foreign handle, but both effect operations and their handlers are codegen'd.
// The outer List is a real capture; the same-name extern arm parameter is not.
fn compile_extern_shadow_probe(foreign: ForeignShadow) {
    let shadowed: List<Int> = [1]
    handle {
        OuterDispatch.run(1)
    } with {
        OuterDispatch.run(outer_value) => {
            let observed = shadowed[0] + outer_value
            handle {
                InnerDispatch.local_only(observed)
                ExternShadow.inspect(foreign)
            } with {
                InnerDispatch.add(value) => {
                    let ignored_add = value
                },
                InnerDispatch.local_only(value) => {
                    let ignored_value = value
                },
                InnerDispatch.shadow(value) => {
                    let ignored_shadow = value
                },
                ExternShadow.inspect(shadowed) => {
                    let ignored_foreign = shadowed
                },
            }
        },
    }
}

fn main() {
    let mut arm_total = 0
    handle {
        run_accumulate()
    } with {
        Accumulate.add(delta) => {
            arm_total = arm_total + delta
            arm_total = arm_total + 10
        },
        Accumulate.add_twice(delta) => {
            arm_total = arm_total + delta
            arm_total = arm_total + delta
        },
    }
    assert(arm_total == 28, "multiple arms share repeated mutable updates")

    // A nested handle in the handled body does not require transitive capture
    // through an arm closure, but remains a useful adjacent-scope baseline.
    let mut outer_total = 0
    let mut inner_total = 0
    handle {
        NestedBump.bump(1)
        handle {
            NestedBump.bump(2)
        } with {
            NestedBump.bump(delta) => {
                inner_total = inner_total + delta
                inner_total = inner_total + 20
            },
        }
        NestedBump.bump(3)
    } with {
        NestedBump.bump(delta) => {
            outer_total = outer_total + delta
            outer_total = outer_total + 10
        },
    }
    assert(outer_total == 24, "outer handler keeps its mutable capture")
    assert(inner_total == 22, "nested handler keeps its mutable capture")

    // True arm-in-arm nesting: the outer handler closure constructs an inner
    // handler, and an inner arm constructs a third-level handler. Main-scope
    // captures must be forwarded transitively through every closure.
    let mut nested_total = 0
    let shadowed: List<Int> = [40]
    let false_capture: List<Int> = [99]
    let outer_set: Set<Int> = set_from([1, 2, 3])
    let inner_set: Set<Int> = set_from([4, 5])
    handle {
        OuterDispatch.run(5)
    } with {
        OuterDispatch.run(outer_value) => {
            nested_total = nested_total + shadowed[0]
            handle {
                InnerDispatch.add(7)
                InnerDispatch.local_only(11)
                InnerDispatch.shadow(inner_set)
            } with {
                InnerDispatch.add(inner_value) => {
                    nested_total = nested_total + outer_value
                    nested_total = nested_total + inner_value
                    nested_total = nested_total + outer_set.len()
                    handle {
                        DeepDispatch.finish(13)
                    } with {
                        DeepDispatch.finish(deep_value) => {
                            nested_total = nested_total + outer_value
                            nested_total = nested_total + inner_value
                            nested_total = nested_total + deep_value
                            nested_total = nested_total + outer_set.len()
                        },
                    }
                },
                // This parameter is the only in-arm use of `false_capture`;
                // the same-name main local must not become a fake capture.
                InnerDispatch.local_only(false_capture) => {
                    nested_total = nested_total + false_capture
                },
                // A second ordinary shadowing arm remains isolated too.
                InnerDispatch.shadow(shadowed) => {
                    nested_total = nested_total + shadowed.len()
                },
            }
        },
    }
    assert(nested_total == 96, "handler arms forward lexical captures transitively")
    assert(false_capture.len() == 1, "handler params do not create false captures")

    let mut closure_total = 0
    let bump_closure = fn(delta: Int) {
        closure_total = closure_total + delta
        closure_total = closure_total + 1
    }
    bump_closure(4)
    closure_total = closure_total + 2
    assert(closure_total == 7, "adjacent ordinary closure keeps its own depth")

    print("effect_handler_mut_capture: all tests passed")
}
