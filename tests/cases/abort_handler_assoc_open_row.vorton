// Owner-qualified associated types in a newly refined callback fail row must
// map back to the exact registration owner, even when another owner has the
// same associated type name.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

struct Words {}
struct Numbers {}

impl Source for Words {
    type Item = Str
    fn get(self) -> Str { "word" }
}

impl Source for Numbers {
    type Item = Int
    fn get(self) -> Int { 7 }
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("assoc")
}

fn recover_one<T: Source>(source: T, callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => 77,
    }
}

fn recover_owned<T: Source, U: Source>(
    left: T, right: U, callback: fn() -> Int
) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => 88,
    }
}

// A predeclared fail<T::Item> callback row and the inferred outer effect use
// the same owner-qualified payload. update_fn_effects must not turn the
// check-time outer variable into a false registration target.
fn propagate_owned<T: Source>(
    source: T, callback: fn() -> Int with {fail<T::Item>}
) -> Int {
    callback()
}

fn main() {
    let direct = recover_one(Words {}, fn() -> Int { raise_text() })
    let qualified = recover_owned(
        Words {}, Numbers {}, fn() -> Int { raise_text() }
    )
    let propagated = propagate_owned(
        Words {}, fn() -> Int { raise_text() }
    ) catch { _ => 99 }
    assert(direct == 77, "direct associated payload owner is preserved")
    assert(qualified == 88, "T::Item is not rebound through U::Item")
    assert(propagated == 99, "predeclared associated payload propagates")
    print("assoc-open=${direct}/${qualified}/${propagated}")
}
