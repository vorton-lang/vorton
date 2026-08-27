pub fn marker() -> Int { 0 }

pub struct BridgeCtx { value: Int }
pub struct BridgeResource { id: Int, payload: Str }

// Intentional project-internal forward declaration: provider imports this
// module, so a normal reverse use would create a dependency cycle.
extern fn bridge(value: Int) -> Int
extern fn bridge_ctx(mut ctx: BridgeCtx) -> Int
extern fn bridge_effect_contract() -> Int with {}
extern fn borrow_resource(value: BridgeResource) -> Int

// This remains genuine FFI even though another project module defines a
// same-signature Ring function named parse_int: that module does not depend
// on this declaration module.
extern fn parse_int(value: Str) -> Option<Int>

pub fn call_bridge() -> Int { bridge(41) }
pub fn call_mut_bridge() -> Int { bridge_ctx(BridgeCtx { value: 5 }) }
pub fn call_effect_bridge() -> Int { bridge_effect_contract() }
pub fn call_borrow_resource() -> Int {
    let value = BridgeResource { id: 7, payload: "forward" }
    let callback = borrow_resource
    let observed = callback(value)
    observed + value.id
}
pub fn call_ffi() -> Int { parse_int("7").unwrap_or(0) }
