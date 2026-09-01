// Audit #251 regression: an abort handler refines an otherwise-open callback
// row to fail<payload> plus a polymorphic residual row. The refinement must be
// written back to the function scheme so compatible callbacks execute and the
// handled fail does not escape.

fn recover(callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

// A monomorphic registration TypeVar may expand directly to the inferred
// callback shape. Its concrete Str payload remains fixed across calls.
fn recover_unannotated(callback) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

// The explicit fail<Str> and the callback's open tail share one exact abort
// payload contract. With no lacks/optional-label row constraint, the callback
// is conservatively required to contain the same fail<Str>.
fn recover_mixed(callback: fn() -> Int, direct: Bool) -> Int {
    handle {
        if direct {
            fail.raise("direct")
        }
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

fn apply(callback: fn() -> Int) -> Int {
    callback()
}

// With no payload annotation or use, fail's operation parameter remains
// polymorphic. Refining the checked callback parameter must generalize that
// new payload variable when the function scheme is rebound.
fn recover_any(callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        fail.raise(unused) => 0,
    }
}

// Matching registration/check structures recurse to nested function nodes;
// only the inner callback row is refined.
fn recover_nested(callbacks: List<fn() -> Int>) -> Int {
    handle {
        let callback = callbacks[0]
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("open-row")
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn raise_text_with_io() -> Int with {fail<Str>, console} {
    print("residual-io")
    fail.raise("open-row")
}

fn main() {
    // The same recover scheme first closes its residual row...
    let recovered = recover(fn() -> Int { raise_text() })
    let recovered_unannotated = recover_unannotated(
        fn() -> Int { raise_text() }
    )
    // ...then instantiates it as io. The handler removes fail<Str>, while io
    // remains observable and escapes through recover.
    let residual = recover(fn() -> Int { raise_text_with_io() })
    let mixed = recover_mixed(fn() -> Int { raise_text() }, false)

    // Ordinary effect-polymorphic HOF inference remains unchanged for both a
    // pure callback and a callback whose fail row escapes to an outer catch.
    let pure = apply(fn() -> Int { 7 })
    let propagated = apply(fn() -> Int { raise_text() }) catch { _ => 9 }

    // A closed pure body remains valid: only an actual open tail is refined.
    let normal = handle {
        41
    } with {
        fail.raise(message: Str) => message.len(),
    }

    // An ordinary closed concrete fail row remains valid and needs no tail
    // refinement.
    let closed = handle {
        raise_text()
    } with {
        fail.raise(message: Str) => message.len(),
    }

    // The newly written-back fail<E> payload is generalized, so the same HOF
    // scheme can instantiate E as Str and then Int in one caller.
    let any_text = recover_any(fn() -> Int { raise_text() })
    let any_number = recover_any(fn() -> Int { raise_number() })
    let nested = recover_nested([fn() -> Int { raise_text() }])

    assert(recovered == 8, "open callback fail is handled")
    assert(recovered_unannotated == 8, "unannotated callback shape is refined")
    assert(residual == 8, "non-fail residual effect is preserved")
    assert(mixed == 8, "mixed concrete and open fail rows agree")
    assert(pure == 7, "pure HOF callback remains valid")
    assert(propagated == 9, "ordinary HOF still propagates fail")
    assert(normal == 41, "closed pure handled body remains valid")
    assert(closed == 8, "closed concrete fail body remains valid")
    assert(any_text == 0 && any_number == 0, "abort payload type is generalized")
    assert(nested == 8, "nested callback row is refined")
    print("open-row=${recovered}/${recovered_unannotated} residual=${residual} mixed=${mixed} pure=${pure} propagated=${propagated} normal=${normal} closed=${closed} any=${any_text}/${any_number} nested=${nested}")
}
