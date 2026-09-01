use forward::{call_bridge, call_mut_bridge, call_effect_bridge,
    call_borrow_resource, call_token_bridge,
    call_generic_bridge_int, call_generic_bridge_str,
    call_generic_select_int, call_generic_select_str, call_ffi}
use provider::{keep_provider}
use decoy::{keep_decoy}

fn main() {
    print(call_bridge() + keep_provider() + keep_decoy())
    print(call_mut_bridge())
    print(call_effect_bridge())
    print(call_borrow_resource())
    print(call_token_bridge())
    print(call_generic_bridge_int())
    print(call_generic_bridge_str())
    print(call_generic_select_int())
    print(call_generic_select_str())
    print(call_ffi())
}
