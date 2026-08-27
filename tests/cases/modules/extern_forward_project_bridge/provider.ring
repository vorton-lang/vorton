use forward::{BridgeCtx, BridgeResource, Token, marker}

pub fn bridge(value: Int) -> Int { value + 1 }
pub fn bridge_ctx(mut ctx: BridgeCtx) -> Int { ctx.value }

fn compare_ints(a: Int, b: Int) -> Int { a - b }

pub fn bridge_effect_contract() -> Int with {} {
    let mut values = [3, 1, 2]
    values.sort_by(compare_ints)
    values[0]
}

pub fn borrow_resource(value: BridgeResource) -> Int { value.id }
pub fn token_bridge(value: Token) -> Int { value.value + 1 }

pub fn keep_provider() -> Int { marker() }
