// Unique neutral transport from the checker's canonical Type graph to one
// module-local Core type fact.  It is consumed by Core assembly and legacy
// projection; neither consumer may rebuild the relation.

use types::{Type, types_equal}
use ir_identity::{HandledEffectRef, handled_effect_ref_same}
use ir_inventory::{
    EffectOperationRef, effect_operation_ref_effect,
    effect_operation_ref_source_index, effect_operation_ref_same
}
use core_expr::{
    CoreTypeFactRef, core_type_fact_same, core_type_fact_module_key
}

pub struct CoreTypeSourceFact {
    source_type: Type,
    type_fact: CoreTypeFactRef
}

pub fn make_core_type_source_fact(
    source_type: Type, type_fact: CoreTypeFactRef
) -> CoreTypeSourceFact {
    CoreTypeSourceFact { source_type: source_type, type_fact: type_fact }
}
pub fn core_type_source_type(value: CoreTypeSourceFact) -> Type {
    value.source_type
}
pub fn core_type_source_fact(value: CoreTypeSourceFact) -> CoreTypeFactRef {
    value.type_fact
}
pub fn core_type_source_same(
    left: CoreTypeSourceFact, right: CoreTypeSourceFact
) -> Bool {
    types_equal(left.source_type, right.source_type) &&
        core_type_fact_same(left.type_fact, right.type_fact)
}

// The handler evidence aggregate has no source spelling or source Type.  The
// checker records its one Core type fact beside the exact declaration-order
// operation signatures; Core assembly consumes this relation directly rather
// than inventing an opaque Ptr/record or replaying effect lookup by name.
pub struct CoreHandledEvidenceOperationTypeSource {
    operation: EffectOperationRef,
    signature_fact: CoreTypeFactRef
}

pub fn make_core_handled_evidence_operation_type_source(
    operation: EffectOperationRef, signature_fact: CoreTypeFactRef
) -> CoreHandledEvidenceOperationTypeSource {
    CoreHandledEvidenceOperationTypeSource {
        operation: operation, signature_fact: signature_fact
    }
}
pub fn core_handled_operation_source_operation(
    value: CoreHandledEvidenceOperationTypeSource
) -> EffectOperationRef { value.operation }
pub fn core_handled_operation_source_signature_fact(
    value: CoreHandledEvidenceOperationTypeSource
) -> CoreTypeFactRef { value.signature_fact }

fn copy_handled_operation_sources(
    values: List<CoreHandledEvidenceOperationTypeSource>
) -> List<CoreHandledEvidenceOperationTypeSource> {
    values.map(fn(value) {
        make_core_handled_evidence_operation_type_source(
            value.operation, value.signature_fact)
    })
}

pub struct CoreHandledEvidenceTypeSource {
    requirement: HandledEffectRef,
    aggregate_fact: CoreTypeFactRef,
    operations: List<CoreHandledEvidenceOperationTypeSource>
}

pub fn make_core_handled_evidence_type_source(
    requirement: HandledEffectRef, aggregate_fact: CoreTypeFactRef,
    operations: List<CoreHandledEvidenceOperationTypeSource>
) -> CoreHandledEvidenceTypeSource {
    // An imported handled effect receives one recorder-local aggregate
    // prototype in every consumer module. The requirement/operation identities
    // remain anchored at the exporter; only Core type-fact ordinals are local.
    let module_key = core_type_fact_module_key(aggregate_fact)
    let mut index = 0
    while index < operations.len() {
        let operation = operations.get(index).unwrap()
        if !handled_effect_ref_same(
                effect_operation_ref_effect(operation.operation),
                requirement) ||
           effect_operation_ref_source_index(operation.operation) != index ||
           core_type_fact_module_key(operation.signature_fact) != module_key ||
           core_type_fact_same(operation.signature_fact, aggregate_fact) {
            panic("Core type source: handled operation contract differs")
        }
        let mut right = index + 1
        while right < operations.len() {
            if effect_operation_ref_same(
                    operation.operation,
                    operations.get(right).unwrap().operation) {
                panic("Core type source: handled operation repeats")
            }
            right = right + 1
        }
        index = index + 1
    }
    CoreHandledEvidenceTypeSource {
        requirement: requirement, aggregate_fact: aggregate_fact,
        operations: copy_handled_operation_sources(operations)
    }
}
pub fn core_handled_evidence_source_requirement(
    value: CoreHandledEvidenceTypeSource
) -> HandledEffectRef { value.requirement }
pub fn core_handled_evidence_source_aggregate_fact(
    value: CoreHandledEvidenceTypeSource
) -> CoreTypeFactRef { value.aggregate_fact }
pub fn core_handled_evidence_source_operations(
    value: CoreHandledEvidenceTypeSource
) -> List<CoreHandledEvidenceOperationTypeSource> {
    copy_handled_operation_sources(value.operations)
}
pub fn core_handled_evidence_type_source_same(
    left: CoreHandledEvidenceTypeSource,
    right: CoreHandledEvidenceTypeSource
) -> Bool {
    if !handled_effect_ref_same(left.requirement, right.requirement) ||
       !core_type_fact_same(left.aggregate_fact, right.aggregate_fact) ||
       left.operations.len() != right.operations.len() {
        return false
    }
    let mut index = 0
    while index < left.operations.len() {
        let a = left.operations.get(index).unwrap()
        let b = right.operations.get(index).unwrap()
        if !effect_operation_ref_same(a.operation, b.operation) ||
           !core_type_fact_same(a.signature_fact, b.signature_fact) {
            return false
        }
        index = index + 1
    }
    true
}
