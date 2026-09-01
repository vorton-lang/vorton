// Utility module that wraps extern fn declarations.
// Re-declares parse_int / parse_float (prelude extern fns with runtime
// mappings) so cross-module extern fn import can be tested on C native.

pub extern fn parse_int(s: Str) -> Option<Int>
pub extern fn parse_float(s: Str) -> Option<Float>

pub fn parse_and_double(s: Str) -> Int {
    match parse_int(s) {
        some(n) => n * 2,
        none => 0,
    }
}
