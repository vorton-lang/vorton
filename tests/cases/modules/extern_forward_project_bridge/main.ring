use forward::{call_bridge, call_mut_bridge, call_effect_bridge,
    call_borrow_resource, call_ffi}
use provider::{keep_provider}
use decoy::{keep_decoy}

fn main() {
    print(call_bridge() + keep_provider() + keep_decoy())
    print(call_mut_bridge())
    print(call_effect_bridge())
    print(call_borrow_resource())
    print(call_ffi())
}
