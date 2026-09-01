use forward::{marker}

// Same leaf as the forward, incompatible signature: never an exact match.
pub fn bridge(value: Str) -> Str { value }

// Same leaf as a real FFI declaration but a different contract: it must not
// capture the raw ABI call even though this module depends on forward.
pub fn parse_int(value: Int) -> Int { value }

// The rendered type leaf is deliberately identical to forward::Token.  Exact
// Core nominal identity must keep this candidate distinct.
pub struct Token { value: Int }
pub fn token_bridge(value: Token) -> Int { value.value + 100 }

pub fn keep_decoy() -> Int { marker() }
