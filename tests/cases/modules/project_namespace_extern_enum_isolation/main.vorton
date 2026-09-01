use defs

fn accept_handle(callback: fn(PublicHandle) -> PublicHandle) -> Int {
    1
}

fn accept_direct(callback: fn(ffi::Handle) -> ffi::Handle) -> Int {
    2
}

fn accept_facade(callback: fn(facade::Handle) -> facade::Handle) -> Int {
    3
}

fn main() {
    print(accept_handle(keep_public))
    print(accept_direct(ffi::keep))
    print(accept_facade(facade::keep))
    print(value_facade::LeafDecoy())
    print(left::value())
    print(left::empty_value())
    print(left::record_value())
    print(right::value())
    print(Same(3))
}
