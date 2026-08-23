// C0 physical CoreHIR schema and body-anchor closure.
//
// This module has no pipeline producer or consumer.  A CoreBodyEntry records
// only the exact executable, its exact origin, and the already-validated body
// anchor declared by ExecutableInventory.  It does not store or expose a
// legacy HIR body and makes no semantic-closure claim.  C1 will add the first
// private Core expression tree and its material valid/invalid probes.

use ir_identity::{OriginRef, PathRef, path_ref_same}
use ir_inventory::{
    ExecutableRef, ExecutableInventory,
    BinderManifest, IrInventoryClosure,
    executable_ref_same,
    executable_entry_reference, executable_entry_contract,
    executable_contract_mode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only,
    executable_contract_body_path,
    executable_inventory_entries,
    close_ir_inventory,
    ir_inventory_closure_inventory,
    ir_inventory_closure_manifests}

pub struct CoreBodyEntry {
    reference: ExecutableRef,
    origin: OriginRef,
    body_anchor: PathRef
}

pub fn make_core_body_entry(
    reference: ExecutableRef, origin: OriginRef, body_anchor: PathRef
) -> CoreBodyEntry {
    CoreBodyEntry {
        reference: reference,
        origin: origin,
        body_anchor: body_anchor
    }
}

fn copy_core_body_entries(values: List<CoreBodyEntry>) -> List<CoreBodyEntry> {
    let mut result: List<CoreBodyEntry> = []
    for value in values {
        result.push(CoreBodyEntry {
            reference: value.reference,
            origin: value.origin,
            body_anchor: value.body_anchor
        })
    }
    result
}

fn core_body_refs_are_unique(values: List<CoreBodyEntry>) -> Bool {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < values.len() {
            let right = values.get(right_index).unwrap()
            if executable_ref_same(left.reference, right.reference) {
                return false
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    true
}

// Bodies form the exact concrete-body subsequence of ExecutableInventory.
// ContractOnly entries have no body anchor.  Matching is positional and exact;
// sorting or searching by a display spelling would create a second authority.
fn validate_core_body_subsequence(
    bodies: List<CoreBodyEntry>, inventory: ExecutableInventory
) {
    if !core_body_refs_are_unique(bodies) {
        panic("CoreHIR: duplicate executable body reference")
    }
    let entries = executable_inventory_entries(inventory)
    let mut body_index = 0
    for entry in entries {
        let contract = executable_entry_contract(entry)
        let mode = executable_contract_mode(contract)
        if executable_contract_mode_same(
                mode, executable_contract_mode_concrete_body()) {
            let body = match bodies.get(body_index) {
                some(value) => value,
                none => panic("CoreHIR: concrete executable body is missing")
            }
            if !executable_ref_same(
                    body.reference, executable_entry_reference(entry)) {
                panic("CoreHIR: body order differs from executable inventory")
            }
            if !path_ref_same(
                    body.body_anchor,
                    executable_contract_body_path(contract)) {
                panic("CoreHIR: body anchor differs from executable contract")
            }
            body_index = body_index + 1
        } else if !executable_contract_mode_same(
                mode, executable_contract_mode_contract_only()) {
            panic("CoreHIR: executable contract mode is invalid")
        }
    }
    if body_index != bodies.len() {
        panic("CoreHIR: body has no concrete executable inventory entry")
    }
}

pub struct CoreProgram {
    closure: IrInventoryClosure,
    bodies: List<CoreBodyEntry>
}

pub fn make_core_program(
    bodies: List<CoreBodyEntry>, inventory: ExecutableInventory,
    manifests: List<BinderManifest>
) -> CoreProgram {
    let closure = close_ir_inventory(inventory, manifests)
    let closed_inventory = ir_inventory_closure_inventory(closure)
    validate_core_body_subsequence(bodies, closed_inventory)
    CoreProgram {
        closure: closure,
        bodies: copy_core_body_entries(bodies)
    }
}

pub fn core_program_body_count(value: CoreProgram) -> Int {
    value.bodies.len()
}

pub fn core_program_inventory(value: CoreProgram) -> ExecutableInventory {
    ir_inventory_closure_inventory(value.closure)
}

pub fn core_program_manifests(value: CoreProgram) -> List<BinderManifest> {
    ir_inventory_closure_manifests(value.closure)
}
