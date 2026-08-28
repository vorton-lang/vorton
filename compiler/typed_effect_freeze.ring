// TypedHIR's one-way effect-header seal.
//
// Final definition schemas and their import localization are the sole
// producers of raw-tail provenance and stable EffectParamRef identities.
// This module never walks HIR to choose
// an owner or ordinal; it only seals the explicit TypeEnv fact tables before
// Core consumes them.  Any missing HIR tail therefore fails at Core's exact
// raw-tail lookup instead of being reconstructed here.

use env::{
    TypeEnv, type_env_effect_formal_facts,
    type_env_callable_effect_facts
}
use effect_contract::{
    TypedEffectFormalFact,
    typed_effect_formal_raw_tail
}

pub use effect_contract::{
    TypedCallableEffectFact,
    typed_callable_effect_reference, typed_callable_effect_row
}

pub struct TypedEffectFreezeResult {
    formals: List<TypedEffectFormalFact>,
    callables: List<TypedCallableEffectFact>
}

pub fn typed_effect_freeze_formals(
    value: TypedEffectFreezeResult
) -> List<TypedEffectFormalFact> {
    value.formals.map(fn(fact) { fact })
}

pub fn typed_effect_freeze_callables(
    value: TypedEffectFreezeResult
) -> List<TypedCallableEffectFact> {
    value.callables.map(fn(fact) { fact })
}

fn validate_formal_facts(values: List<TypedEffectFormalFact>) {
    let mut fact_index = 0
    while fact_index < values.len() {
        let fact = values.get(fact_index).unwrap()
        let raw_tail = typed_effect_formal_raw_tail(fact)
        let mut prior = 0
        while prior < fact_index {
            if typed_effect_formal_raw_tail(values.get(prior).unwrap()) ==
                    raw_tail {
                panic("typed effect freeze: raw tail maps twice")
            }
            prior = prior + 1
        }
        fact_index = fact_index + 1
    }
}

pub fn freeze_typed_effect_formals(
    env: TypeEnv
) -> TypedEffectFreezeResult {
    let formals = type_env_effect_formal_facts(env)
    validate_formal_facts(formals)
    TypedEffectFreezeResult {
        formals: formals,
        callables: type_env_callable_effect_facts(env)
    }
}
