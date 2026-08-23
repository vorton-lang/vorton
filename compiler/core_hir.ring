// C0 physical CoreHIR schema.
//
// This module has no pipeline producer or consumer.  It defines the one
// forge-resistant container that later semantic elaboration must construct.
// The provisional recursive gate below accepts only the currently provable
// closed subset; it deliberately does not claim that every unlisted HIR node
// is canonical CoreHIR.

use hir::{HExpr, HStmt, HMatchArm, HEffectHandler,
    HFieldAccessKind, HStringInterpPart}
use ir_identity::{OriginRef}
use ir_inventory::{
    ExecutableRef, ExecutableEntry, ExecutableInventory,
    BinderManifest, IrInventoryClosure,
    executable_ref_same,
    executable_entry_reference, executable_entry_kind,
    executable_entry_contract,
    executable_kind_same, executable_kind_derived_impl,
    executable_kind_default_specialization,
    executable_contract_mode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only,
    executable_inventory_entries,
    close_ir_inventory,
    ir_inventory_closure_inventory,
    ir_inventory_closure_manifests}

fn reject_legacy_trait_dispatch(dispatch_present: Bool) {
    if dispatch_present {
        panic("CoreHIR: legacy TraitDispatch reached provisional close")
    }
}

fn validate_core_match_arm_provisional(arm: HMatchArm) {
    match arm.guard {
        some(guard) => validate_core_expr_provisional(guard),
        none => {}
    }
    validate_core_expr_provisional(arm.body)
}

fn validate_core_handler_provisional(handler: HEffectHandler) {
    validate_core_expr_provisional(handler.body)
}

fn validate_core_stmt_provisional(stmt: HStmt) {
    match stmt {
        HStmt::Let { init, .. } => validate_core_expr_provisional(init),
        HStmt::Var { init, .. } => validate_core_expr_provisional(init),
        HStmt::Assign { target, value, .. } => {
            validate_core_expr_provisional(target)
            validate_core_expr_provisional(value)
        },
        HStmt::ExprStmt { expr, .. } =>
            validate_core_expr_provisional(expr),
        HStmt::Return { value, .. } => match value {
            some(expr) => validate_core_expr_provisional(expr),
            none => {}
        },
        HStmt::While { condition, body, .. } => {
            validate_core_expr_provisional(condition)
            validate_core_expr_provisional(body)
        },
        HStmt::ForIn { .. } =>
            panic("CoreHIR: protocol ForIn reached provisional close"),
        HStmt::Break { .. } => {},
        HStmt::Continue { .. } => {},
        HStmt::LetDestructure { init, .. } =>
            validate_core_expr_provisional(init),
        HStmt::IfLet {
            expr, then_block, else_block, ..
        } => {
            validate_core_expr_provisional(expr)
            validate_core_expr_provisional(then_block)
            match else_block {
                some(branch) => validate_core_expr_provisional(branch),
                none => {}
            }
        },
        HStmt::Drop { .. } =>
            panic("CoreHIR: post-Core Drop reached provisional close")
    }
}

fn validate_core_expr_provisional(expr: HExpr) {
    match expr {
        HExpr::IntLit { .. } => {},
        HExpr::FloatLit { .. } => {},
        HExpr::StrLit { .. } => {},
        HExpr::BoolLit { .. } => {},
        HExpr::Ident { .. } => {},
        HExpr::BinOp {
            left, right, eq_dispatch, ord_dispatch, ..
        } => {
            reject_legacy_trait_dispatch(eq_dispatch.is_some())
            reject_legacy_trait_dispatch(ord_dispatch.is_some())
            validate_core_expr_provisional(left)
            validate_core_expr_provisional(right)
        },
        HExpr::UnaryOp { operand, .. } =>
            validate_core_expr_provisional(operand),
        // HExpr::Call has no CalleeRef today.  Even a none DictDispatchInfo
        // would remain a spelling-selected call, so C0 rejects the whole
        // legacy shape until the formal method/callee cutover.
        HExpr::Call { .. } =>
            panic("CoreHIR: legacy Call has no exact CalleeRef"),
        HExpr::FieldAccess { receiver, access_kind, .. } => {
            match access_kind {
                HFieldAccessKind::Method =>
                    panic("CoreHIR: legacy Method field reached provisional close"),
                HFieldAccessKind::ErrorRecovery =>
                    panic("CoreHIR: ErrorRecovery field reached provisional close"),
                _ => {}
            }
            validate_core_expr_provisional(receiver)
        },
        HExpr::StructLit { fields, spread, .. } => {
            for field in fields {
                validate_core_expr_provisional(field.value)
            }
            match spread {
                some(value) => validate_core_expr_provisional(value),
                none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields {
                validate_core_expr_provisional(field.value)
            }
            match spread {
                some(value) => validate_core_expr_provisional(value),
                none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            validate_core_expr_provisional(scrutinee)
            for arm in arms { validate_core_match_arm_provisional(arm) }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts { validate_core_stmt_provisional(stmt) }
            match tail {
                some(value) => validate_core_expr_provisional(value),
                none => {}
            }
        },
        HExpr::IfExpr {
            condition, then_branch, else_branch, ..
        } => {
            validate_core_expr_provisional(condition)
            validate_core_expr_provisional(then_branch)
            match else_branch {
                some(branch) => validate_core_expr_provisional(branch),
                none => {}
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Literal(_) => {},
                    HStringInterpPart::Expression(value) =>
                        validate_core_expr_provisional(value)
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            validate_core_expr_provisional(body)
            for arm in arms { validate_core_match_arm_provisional(arm) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            validate_core_expr_provisional(body)
            for handler in handlers {
                validate_core_handler_provisional(handler)
            }
        },
        HExpr::Lambda { body, .. } =>
            validate_core_expr_provisional(body),
        HExpr::EffectOp { args, .. } => {
            for arg in args { validate_core_expr_provisional(arg) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            validate_core_expr_provisional(start)
            validate_core_expr_provisional(end)
        },
        HExpr::ListLit { elements, .. } => {
            for element in elements {
                validate_core_expr_provisional(element)
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for element in elements {
                validate_core_expr_provisional(element)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            validate_core_expr_provisional(receiver)
            validate_core_expr_provisional(index)
        },
        HExpr::DictConstruct { .. } =>
            panic("CoreHIR: legacy DictConstruct reached provisional close"),
        HExpr::Clone { .. } =>
            panic("CoreHIR: post-Core Clone reached provisional close"),
        HExpr::ReturnExpr { value, .. } => match value {
            some(result) => validate_core_expr_provisional(result),
            none => {}
        },
        HExpr::UnsafeBlock { body, .. } =>
            validate_core_expr_provisional(body)
    }
}

pub struct CoreBodyEntry {
    reference: ExecutableRef,
    origin: OriginRef,
    body: HExpr
}

pub fn make_core_body_entry(
    reference: ExecutableRef, origin: OriginRef, body: HExpr
) -> CoreBodyEntry {
    validate_core_expr_provisional(body)
    CoreBodyEntry {
        reference: reference,
        origin: origin,
        body: body
    }
}

pub fn core_body_entry_reference(value: CoreBodyEntry) -> ExecutableRef {
    value.reference
}

pub fn core_body_entry_origin(value: CoreBodyEntry) -> OriginRef {
    value.origin
}

pub fn core_body_entry_body(value: CoreBodyEntry) -> HExpr {
    value.body
}

fn copy_core_body_entries(values: List<CoreBodyEntry>) -> List<CoreBodyEntry> {
    let mut result: List<CoreBodyEntry> = []
    for value in values {
        result.push(CoreBodyEntry {
            reference: value.reference,
            origin: value.origin,
            body: value.body
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

fn reject_pending_core_executable(entry: ExecutableEntry) {
    let kind = executable_entry_kind(entry)
    if executable_kind_same(kind, executable_kind_derived_impl()) ||
       executable_kind_same(
            kind, executable_kind_default_specialization()) {
        panic("CoreHIR: pending semantic executable reached close")
    }
}

fn validate_core_body_subsequence(
    bodies: List<CoreBodyEntry>, inventory: ExecutableInventory
) {
    if !core_body_refs_are_unique(bodies) {
        panic("CoreHIR: duplicate executable body reference")
    }
    let entries = executable_inventory_entries(inventory)
    let mut body_index = 0
    for entry in entries {
        reject_pending_core_executable(entry)
        let mode = executable_contract_mode(
            executable_entry_contract(entry))
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

pub fn core_program_bodies(value: CoreProgram) -> List<CoreBodyEntry> {
    copy_core_body_entries(value.bodies)
}
