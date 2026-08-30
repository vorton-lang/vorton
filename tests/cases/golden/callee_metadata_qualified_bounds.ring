// B-107 Unit 2: bounded DirectCallable and ExternCallable metadata follows
// exact DefId provenance through two relative pub-use aliases.

struct Wrap<T> {
    value: T
}

impl<T: Hash> Hash for Wrap<T> {
    fn hash(self) -> Int {
        self.value.hash()
    }
}

pub mod bounded_origin {
    pub fn fingerprint<T: Hash>(value: T) -> Int {
        value.hash()
    }
}

pub mod bounded_decoy {
    // Same source leaf, deliberately unbounded.
    pub fn fingerprint<T>(_value: T) -> Int {
        900
    }
}

pub mod bounded_middle {
    pub use super::bounded_origin::fingerprint as relay
}

pub mod decoy_middle {
    pub use super::bounded_decoy::fingerprint as relay
}

pub mod bounded_facade {
    pub use super::bounded_middle::relay as target
    pub use super::decoy_middle::relay as decoy
}

pub mod foreign_origin {
    pub extern fn ring_print<T: Hash>(value: T) -> Unit with {console}
}

pub mod foreign_middle {
    pub use super::foreign_origin::ring_print as relay
}

pub mod foreign_facade {
    pub use super::foreign_middle::relay as emit
}

fn apply_int(f: fn(Int) -> Int, value: Int) -> Int {
    f(value)
}

fn apply_wrap(f: fn(Wrap<Int>) -> Int, value: Wrap<Int>) -> Int {
    f(value)
}

fn apply_float(f: fn(Float) -> Int, value: Float) -> Int {
    f(value)
}

fn local_shadow(fingerprint: fn(Float) -> Int) -> Int {
    // This exact lexical scheme is unbounded despite the same declaration
    // spelling used by bounded_origin.
    fingerprint(1.5)
}

fn seven(_value: Float) -> Int with {} {
    7
}

fn call_emit(
    emit: fn(Str) -> Unit with {console},
    value: Str
) -> Unit with {console} {
    emit(value)
}

fn main() {
    let direct_int = bounded_facade::target(17)
    assert(direct_int == bounded_origin::fingerprint(17),
        "qualified bounded direct call uses the target scheme")

    let hof_int = apply_int(bounded_facade::target, 18)
    assert(hof_int == bounded_origin::fingerprint(18),
        "qualified bounded function value keeps Int evidence")

    let wrapped = Wrap { value: 19 }
    let hof_wrap = apply_wrap(bounded_facade::target, wrapped)
    assert(hof_wrap == bounded_origin::fingerprint(Wrap { value: 19 }),
        "qualified bounded function value builds Wrap<Int> evidence")

    assert(apply_float(bounded_facade::decoy, 1.5) == 900,
        "same-leaf unbounded decoy remains independent")
    assert(local_shadow(seven) == 7,
        "same-name LocalBorrow does not inherit global bounds")

    // Extern bounds are checked statically, but neither direct nor first-class
    // foreign calls may carry a Ring dictionary argument.
    foreign_facade::emit("107")
    call_emit(foreign_facade::emit, "108")
    print("callee metadata qualified bounds: all ok")
}
