// The sole 0.1 ordinary-body adapter retained outside the real HIR->Core
// producer. Trait defaults and derived bodies use their direct producers;
// default specialization alone needs this small assembly helper.

use ir_identity::{CoreTypeRef, SlotRef, OriginRef}
use ir_inventory::{ExecutableRef}
use core_expr::{
    CoreBinder, CoreBody, CoreStmt, CoreExpr,
    make_core_block, make_core_body, validate_core_body
}

pub struct CoreOrdinaryBodyPlan {
    reference: ExecutableRef,
    origin: OriginRef,
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    statements: List<CoreStmt>,
    tail: CoreExpr?,
    body_origin: OriginRef
}

pub fn make_core_ordinary_body_plan(
    reference: ExecutableRef, origin: OriginRef,
    binders: List<CoreBinder>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, statements: List<CoreStmt>, tail: CoreExpr?,
    body_origin: OriginRef
) -> CoreOrdinaryBodyPlan {
    CoreOrdinaryBodyPlan {
        reference: reference, origin: origin,
        binders: binders.map(fn(value) { value }),
        parameter_slots: parameter_slots.map(fn(value) { value }),
        result_type: result_type,
        statements: statements.map(fn(value) { value }),
        tail: tail, body_origin: body_origin
    }
}

pub fn elaborate_core_default_specialization(
    plan: CoreOrdinaryBodyPlan
) -> CoreBody {
    let body = make_core_body(
        plan.reference, plan.origin, plan.binders, plan.parameter_slots,
        plan.result_type,
        make_core_block(plan.statements, plan.tail, plan.body_origin))
    validate_core_body(body)
    body
}
