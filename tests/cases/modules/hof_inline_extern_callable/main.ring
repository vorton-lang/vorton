use defs

pub mod ffi {
    pub extern fn parse_int(value: Str) -> Option<Int> with {}
}

fn apply_parse(
    parser: fn(Str) -> Option<Int>,
    value: Str,
) -> Option<Int> {
    parser(value)
}

fn main() {
    match ffi::parse_int("41") {
        some(value) => print(value),
        none => panic("inline extern direct call failed"),
    }
    match apply_parse(ffi::parse_int, "42") {
        some(value) => print(value),
        none => panic("inline extern function value failed"),
    }
    // Both facade values cross two relative pub-use hops. Their declarations
    // have the same `parse_int` leaf (and the middle aliases share `parser`),
    // so only final DefId provenance can distinguish extern from Ring code.
    match apply_parse(facade::external_parser, "43") {
        some(value) => print(value),
        none => panic("relative file extern function value failed"),
    }
    match apply_parse(facade::ring_parser, "ignored") {
        some(value) => print(value),
        none => panic("same-leaf Ring function value failed"),
    }
}
