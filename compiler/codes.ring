// Error/Warning code numbering:
// E01xx = Lexer/Parser errors
// E02xx = Name resolution / scope errors
// E03xx = Type errors
// E04xx = Effect errors
// E05xx = Trait errors
// E06xx = Exhaustiveness errors
// E07xx = Module errors
// W0xxx = Warnings
// Gaps in numbering (E0202, E0400, E0401, E0701, etc.) are from removed/merged codes.

pub const E0101: Str = "E0101"
pub const E0102: Str = "E0102"
pub const E0103: Str = "E0103"
pub const E0104: Str = "E0104"
pub const E0105: Str = "E0105"
pub const E0201: Str = "E0201"
pub const E0203: Str = "E0203"
pub const E0204: Str = "E0204"
pub const E0205: Str = "E0205"
pub const E0206: Str = "E0206"
pub const E0207: Str = "E0207"
pub const E0208: Str = "E0208"
pub const E0301: Str = "E0301"
pub const E0302: Str = "E0302"
pub const E0303: Str = "E0303"
pub const E0304: Str = "E0304"
pub const E0305: Str = "E0305"
pub const E0306: Str = "E0306"
pub const E0307: Str = "E0307"
pub const E0308: Str = "E0308"
pub const E0309: Str = "E0309"
pub const E0402: Str = "E0402"
pub const E0403: Str = "E0403"
pub const E0404: Str = "E0404"
pub const E0501: Str = "E0501"
pub const E0502: Str = "E0502"
pub const E0503: Str = "E0503"
pub const E0405: Str = "E0405"
pub const E0406: Str = "E0406"
pub const E0407: Str = "E0407"
// Reserved: open effect row in capability-restricted module.
// Not emitted — see check_effects_capability in infer_decl.ring for rationale:
// open row tails represent effect polymorphism, not capability violations.
pub const E0408: Str = "E0408"
pub const E0504: Str = "E0504"
pub const E0505: Str = "E0505"
pub const E0506: Str = "E0506"
pub const E0507: Str = "E0507"
pub const E0508: Str = "E0508"
pub const E0411: Str = "E0411"
pub const E0509: Str = "E0509"
pub const E0510: Str = "E0510"
pub const E0511: Str = "E0511"
pub const E0512: Str = "E0512"
pub const E0513: Str = "E0513"
pub const E0514: Str = "E0514"
pub const E0601: Str = "E0601"
pub const E0702: Str = "E0702"
pub const E0703: Str = "E0703"
pub const E0704: Str = "E0704"
pub const E0705: Str = "E0705"
pub const E0706: Str = "E0706"
pub const E0707: Str = "E0707"
pub const E0708: Str = "E0708"

// E08xx = Ownership errors
pub const E0801: Str = "E0801"
pub const E0802: Str = "E0802"
pub const E0803: Str = "E0803"

pub const W0001: Str = "W0001"
pub const W0002: Str = "W0002"

pub fn error_description(code: Str) -> Str {
    if code == "E0101" { return "Unexpected token" }
    if code == "E0102" { return "Unterminated string literal" }
    if code == "E0103" { return "Expected token" }
    if code == "E0104" { return "Empty parentheses on enum variant" }
    if code == "E0105" { return "Invalid impl type argument" }
    if code == "E0201" { return "Undefined variable" }
    if code == "E0203" { return "Unknown struct or invalid constructor fields" }
    if code == "E0204" { return "Unknown type" }
    if code == "E0205" { return "Assignment to immutable variable" }
    if code == "E0206" { return "Break/continue outside loop" }
    if code == "E0207" { return "Duplicate definition" }
    if code == "E0208" { return "Mutating method on immutable binding" }
    if code == "E0301" { return "Type mismatch" }
    if code == "E0302" { return "Infinite type (occurs check)" }
    if code == "E0303" { return "Numeric type required" }
    if code == "E0304" { return "Invalid field access" }
    if code == "E0305" { return "Undefined method" }
    if code == "E0306" { return "Type does not support indexing" }
    if code == "E0307" { return "Type does not implement Eq" }
    if code == "E0308" { return "Type does not implement Ord" }
    if code == "E0309" { return "Type not interpolatable" }
    if code == "E0402" { return "Unknown effect operation" }
    if code == "E0403" { return "Unhandled effect" }
    if code == "E0404" { return "Effect annotation violation" }
    if code == "E0405" { return "Capability violation" }
    if code == "E0406" { return "Cyclic effect alias" }
    if code == "E0407" { return "Unknown effect" }
    // Reserved: not currently emitted (open row ≠ capability violation, see infer_decl.ring)
    if code == "E0408" { return "Open effect row in capability-restricted module" }
    if code == "E0411" { return "Unsafe block without module requires" }
    if code == "E0501" { return "Unknown trait" }
    if code == "E0502" { return "Missing trait method implementation" }
    if code == "E0503" { return "Unsatisfied trait bound" }
    if code == "E0504" { return "Ambiguous trait method" }
    if code == "E0505" { return "Missing supertrait implementation" }
    if code == "E0506" { return "Cyclic supertrait inheritance" }
    if code == "E0507" { return "Delegate field not found" }
    if code == "E0508" { return "Delegate field type does not implement trait" }
    if code == "E0509" { return "Delegate conflicts with existing impl" }
    if code == "E0510" { return "Missing associated type implementation" }
    if code == "E0511" { return "Unknown associated type" }
    if code == "E0512" { return "Ambiguous associated type" }
    if code == "E0513" { return "Associated type bound not satisfied" }
    if code == "E0514" { return "Unexpected associated type" }
    if code == "E0601" { return "Non-exhaustive pattern match" }
    if code == "E0702" { return "Module not found" }
    if code == "E0703" { return "Symbol not found in module" }
    if code == "E0704" { return "Circular dependency detected" }
    if code == "E0705" { return "Relative path out of scope" }
    if code == "E0706" { return "Use declaration must appear before other declarations" }
    if code == "E0707" { return "Ambiguous import" }
    if code == "E0708" { return "Ambiguous project extern forward" }
    if code == "E0801" { return "Use of moved value" }
    if code == "E0802" { return "Drop-Clone conflict" }
    if code == "E0803" { return "Drop method must not fail" }
    if code == "W0001" { return "Catch on expression with no fail effect" }
    if code == "W0002" { return "Refinement where clause not enforced" }
    "Unknown error"
}

pub fn error_category(code: Str) -> Str {
    if code.starts_with("E01") { return "parse" }
    if code.starts_with("E02") { return "resolution" }
    if code.starts_with("E03") { return "type" }
    if code.starts_with("E04") { return "effect" }
    if code.starts_with("E05") { return "trait" }
    if code.starts_with("E06") { return "pattern" }
    if code.starts_with("E07") { return "module" }
    if code.starts_with("E08") { return "ownership" }
    if code.starts_with("W") { return "warning" }
    "unknown"
}
