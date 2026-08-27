// 0.1 TypedHIR -> Core-ready HIR semantic closure.
//
// This is the sole pass which consumes surface-only HIR shapes. Every
// lowering is driven by an exact plan attached at the first-known inference
// site. Names and spans below are diagnostic payload only; they never select a
// callee, method, projection, constructor, pattern, dictionary, or binder.

use ast::{Span, Pattern, NamedPatternField, BinOp}
use types::{
    Type, Effect, EffectRow, EMPTY_ROW, effects_equal, types_equal
}
use ir_identity::{
    SymbolRef, CalleeRef, SlotRef, HandledEffectRef,
    make_named_callee_ref, make_dynamic_callee_ref,
    callee_ref_is_named, callee_ref_named_symbol,
    symbol_ref_canonical_payload, symbol_ref_same,
    system_effect_ref_same,
    handled_effect_ref_same,
    make_registered_nominal_ref,
    nominal_field_ref_owner, nominal_field_ref_index, nominal_field_ref_name,
    nominal_field_ref_same,
    variant_field_ref_index, variant_field_ref_same,
    intrinsic_ref_symbol, trait_method_ref_member, impl_method_ref_member,
    impl_provider_ref_kind, impl_provider_kind_delegate,
    impl_provider_kind_same,
    slot_ref_same, slot_ref_is_source, slot_ref_source_def_id
}
use ir_inventory::{
    ExecutableRef, BinderEntry, HandledEvidenceRef,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_anonymous_path, executable_ref_origin_module_key,
    system_host_callable_effect, system_host_callable_executable,
    binder_entry_slot, handled_evidence_requirement,
    effect_operation_ref_effect, make_exact_wrapped_dict_ref,
    dict_ref_same
}
use env::{TypeEnv}
use hir::{
    HProgram, HDecl, HStmt, HExpr, HMatchArm, HEffectHandler, DictRef,
    HStringInterpPart, HLambdaCapture,
    HNominalStructFieldInit, HStructFieldInit,
    HTraitMethod, HEffectOp, TraitBound, HTypeParam,
    HForInDestructure, HLetDestructureBinding, HPatternBinding,
    HProjectionRef, HExactCallPlan,
    HStringInterpPlan, HListLiteralPlan, HDictConstructPlan,
    HPatternPlan, HPatternFieldPlan, HForInPlan,
    HFieldAccessKind,
    make_h_exact_call_plan,
    h_exact_call_callee, h_exact_call_signature,
    h_exact_call_method, h_exact_call_evidence,
    h_exact_call_handled_evidence,
    h_constructor_kind,
    h_constructor_fields, h_constructor_tuple_arity,
    h_string_interp_builder_binder, h_string_interp_builder,
    h_string_interp_append_literal, h_string_interp_append_value,
    h_string_interp_finish, h_string_interp_value_to_string,
    h_list_literal_builder, h_list_literal_owner,
    h_list_literal_constructor, h_list_literal_allocator,
    h_list_literal_push,
    h_dict_construct_executable, h_dict_construct_trait,
    h_pattern_kind, h_pattern_plan_binding, h_pattern_plan_children,
    h_pattern_plan_fields, h_pattern_plan_struct_owner,
    h_pattern_plan_variant, h_pattern_field_projection,
    h_pattern_field_pattern, make_h_pattern_field_plan,
    h_pattern_wildcard, h_pattern_binding,
    h_pattern_tuple, h_pattern_struct, h_pattern_variant,
    h_nominal_projection,
    h_for_in_binding_binder,
    h_range_for_in_start, h_range_for_in_end,
    h_range_for_in_inclusive, h_range_for_in_order,
    h_range_for_in_equality,
    h_range_for_in_range_binder, h_range_for_in_counter_binder,
    h_range_for_in_finished_binder,
    h_fail_operation_tag,
    h_projection_kind, h_projection_nominal, h_projection_variant,
    h_projection_structural, h_projection_structural_name,
    h_projection_tuple_index,
    h_projection_intrinsic,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_intrinsic, method_call_ref_impl,
    method_call_ref_bound,
    hexpr_type, hexpr_effects, hexpr_span,
    validate_hir_binder_def_ids
}
use hir_exact::{
    make_wrapped_dict_ref, dict_ref_exact,
    h_dict_construct_base, h_dict_construct_inner,
    h_dict_construct_result
}

struct ClosedPattern {
    pattern: Pattern,
    plan: HPatternPlan
}

struct ClosedPatternSequence {
    patterns: List<Pattern>,
    plans: List<HPatternPlan>
}

fn copy_patterns(values: List<Pattern>) -> List<Pattern> {
    let mut result: List<Pattern> = []
    for value in values { result.push(value) }
    result
}
fn copy_pattern_plans(values: List<HPatternPlan>) -> List<HPatternPlan> {
    let mut result: List<HPatternPlan> = []
    for value in values { result.push(value) }
    result
}

fn merge_effect_rows(left: EffectRow, right: EffectRow) -> EffectRow {
    if left.tail.is_some() || right.tail.is_some() {
        panic("PreCore closure: open effect row crossed TypedHIR")
    }
    let mut effects: List<Effect> = left.effects.map(fn(value) { value })
    for candidate in right.effects {
        if !effects.any(fn(existing) { effects_equal(existing, candidate) }) {
            effects.push(candidate)
        }
    }
    EffectRow { effects: effects, tail: none }
}

fn expression_list_effects(values: List<HExpr>) -> EffectRow {
    let mut result = EMPTY_ROW
    for value in values {
        result = merge_effect_rows(result, hexpr_effects(value))
    }
    result
}

fn contains_fail_effect(value: EffectRow) -> Bool {
    value.effects.any(fn(eff) { match eff {
        Effect::FailEffect { .. } => true,
        _ => false
    } })
}

fn exact_method_symbol(plan: HExactCallPlan) -> SymbolRef {
    let method = match h_exact_call_method(plan) {
        some(value) => value,
        none => panic("PreCore closure: exact method plan has no method")
    }
    if method_call_ref_is_intrinsic(method) {
        intrinsic_ref_symbol(method_call_ref_intrinsic(method))
    } else if method_call_ref_is_concrete(method) {
        impl_method_ref_member(method_call_ref_impl(method))
    } else {
        trait_method_ref_member(method_call_ref_bound(method))
    }
}

fn exact_plan_signature(plan: HExactCallPlan) -> Type {
    h_exact_call_signature(plan)
}

fn fn_result_type(value: Type) -> Type {
    match value {
        Type::FnType { return_type, .. } => return_type,
        _ => panic("PreCore closure: exact call signature is not a function")
    }
}

fn fn_parameter_types(value: Type) -> List<Type> {
    match value {
        Type::FnType { params, .. } => params.map(fn(item) { item }),
        _ => panic("PreCore closure: exact call signature is not a function")
    }
}

fn fn_effects(value: Type) -> EffectRow {
    match value {
        Type::FnType { effects, .. } => effects,
        _ => panic("PreCore closure: exact call signature is not a function")
    }
}

fn diagnostic_callee(
    callee: CalleeRef, signature: Type, span: Span
) -> HExpr {
    if !callee_ref_is_named(callee) {
        panic("PreCore closure: generated direct call is not a named callee")
    }
    let symbol = callee_ref_named_symbol(callee)
    let label = symbol_ref_canonical_payload(symbol)
    HExpr::Ident {
        name: label, resolved_name: some(label), def_id: none,
        source_slot: none, callee_identity: some(callee),
        dict_closure_dicts: none, ty: signature,
        effects: EMPTY_ROW, span: span
    }
}

fn exact_call(
    plan: HExactCallPlan, arguments: List<HExpr>, result_type: Type,
    call_effects: EffectRow, span: Span
) -> HExpr {
    let callee_ref = h_exact_call_callee(plan)
    let signature = h_exact_call_signature(plan)
    if !types_equal(fn_result_type(signature), result_type) {
        panic("PreCore closure: exact call/result type differs")
    }
    match h_exact_call_method(plan) {
        some(method) => {
            if arguments.len() == 0 {
                panic("PreCore closure: method call has no receiver")
            }
            let receiver = arguments.get(0).unwrap()
            let mut params: List<HExpr> = []
            let mut index = 1
            while index < arguments.len() {
                params.push(arguments.get(index).unwrap())
                index = index + 1
            }
            let member = exact_method_symbol(plan)
            let field = symbol_ref_canonical_payload(member)
            let callee = HExpr::FieldAccess {
                receiver: receiver, field: field,
                access_kind: HFieldAccessKind::Method,
                projection: none, ty: signature,
                effects: hexpr_effects(receiver), span: span
            }
            HExpr::Call {
                callee: callee, args: params, type_args: [],
                resolved_dicts: h_exact_call_evidence(plan),
                handled_evidence: h_exact_call_handled_evidence(plan),
                callee_ref: none, method_ref: some(method),
                system_host: none, ty: result_type,
                effects: call_effects, span: span
            }
        },
        none => {
            HExpr::Call {
                callee: diagnostic_callee(callee_ref, signature, span),
                args: arguments, type_args: [],
                resolved_dicts: h_exact_call_evidence(plan),
                handled_evidence: h_exact_call_handled_evidence(plan),
                callee_ref: some(callee_ref), method_ref: none,
                system_host: none, ty: result_type,
                effects: call_effects, span: span
            }
        }
    }
}

fn executable_call(
    executable: ExecutableRef, signature: Type, arguments: List<HExpr>,
    evidence: List<DictRef>, result_type: Type,
    effects: EffectRow, span: Span
) -> HExpr {
    let callee = if executable_ref_is_named(executable) {
        make_named_callee_ref(executable_ref_named_symbol(executable))
    } else {
        make_dynamic_callee_ref(executable_ref_anonymous_path(executable))
    }
    exact_call(
        make_h_exact_call_plan(callee, signature, none, evidence, []),
        arguments, result_type, effects, span)
}

fn binder_def_id(value: BinderEntry) -> Int {
    let slot = binder_entry_slot(value)
    if !slot_ref_is_source(slot) {
        panic("PreCore closure: semantic binder is not a source SlotRef")
    }
    slot_ref_source_def_id(slot)
}

fn binder_name(prefix: Str, value: BinderEntry) -> Str {
    "${prefix}_${binder_def_id(value).to_str()}"
}

fn binder_ident(
    name: Str, binder: BinderEntry, ty: Type, span: Span
) -> HExpr {
    let slot = binder_entry_slot(binder)
    HExpr::Ident {
        name: name, resolved_name: none, def_id: some(binder_def_id(binder)),
        source_slot: some(slot), callee_identity: none,
        dict_closure_dicts: none, ty: ty,
        effects: EMPTY_ROW, span: span
    }
}

fn binder_let(
    name: Str, binder: BinderEntry, ty: Type, init: HExpr, span: Span
) -> HStmt {
    HStmt::Let {
        name: name, name_span: span, def_id: some(binder_def_id(binder)),
        ty: ty, init: init, span: span
    }
}

fn binder_var(
    name: Str, binder: BinderEntry, ty: Type, init: HExpr, span: Span
) -> HStmt {
    HStmt::Var {
        name: name, name_span: span, def_id: some(binder_def_id(binder)),
        ty: ty, init: init, span: span
    }
}

fn projection_label(value: HProjectionRef) -> Str {
    match h_projection_kind(value) {
        0 => nominal_field_ref_name(h_projection_nominal(value)),
        1 => "$variant_${variant_field_ref_index(
            h_projection_variant(value)).to_str()}",
        2 => h_projection_structural_name(value),
        3 => h_projection_tuple_index(value).to_str(),
        4 => symbol_ref_canonical_payload(
            intrinsic_ref_symbol(h_projection_intrinsic(value))),
        _ => panic("PreCore closure: invalid exact projection kind")
    }
}

fn projection_access_kind(value: HProjectionRef) -> HFieldAccessKind {
    match h_projection_kind(value) {
        0 => {
            let field = h_projection_nominal(value)
            let owner = nominal_field_ref_owner(field)
            HFieldAccessKind::NominalField {
                owner_ref: make_registered_nominal_ref(
                    owner, symbol_ref_canonical_payload(owner)),
                field_ref: field, field_index: nominal_field_ref_index(field)
            }
        },
        2 => HFieldAccessKind::RecordField,
        3 => HFieldAccessKind::TupleField,
        _ => panic("PreCore closure: projection is not a value field")
    }
}

fn project_expr(
    base: HExpr, projection: HProjectionRef,
    ty: Type, effects: EffectRow, span: Span
) -> HExpr {
    HExpr::FieldAccess {
        receiver: base, field: projection_label(projection),
        access_kind: projection_access_kind(projection),
        projection: some(projection), ty: ty, effects: effects, span: span
    }
}

fn expand_pattern_sequence(
    patterns: List<Pattern>, plans: List<HPatternPlan>
) -> List<ClosedPatternSequence> {
    if patterns.len() != plans.len() {
        panic("PreCore closure: pattern child/plan census differs")
    }
    let mut result: List<ClosedPatternSequence> = [ClosedPatternSequence {
        patterns: [], plans: []
    }]
    let mut index = 0
    while index < patterns.len() {
        let choices = expand_pattern(
            patterns.get(index).unwrap(), plans.get(index).unwrap())
        let mut next: List<ClosedPatternSequence> = []
        for prefix in result {
            for choice in choices {
                let mut next_patterns = copy_patterns(prefix.patterns)
                let mut next_plans = copy_pattern_plans(prefix.plans)
                next_patterns.push(choice.pattern)
                next_plans.push(choice.plan)
                next.push(ClosedPatternSequence {
                    patterns: next_patterns, plans: next_plans
                })
            }
        }
        result = next
        index = index + 1
    }
    result
}

fn projected_plan(
    source: HPatternPlan, children: List<HPatternPlan>
) -> HPatternPlan {
    let fields = h_pattern_plan_fields(source)
    if fields.len() != children.len() {
        panic("PreCore closure: projected pattern child census differs")
    }
    let mut rebuilt: List<HPatternFieldPlan> = []
    let mut index = 0
    while index < children.len() {
        rebuilt.push(make_h_pattern_field_plan(
            h_pattern_field_projection(fields.get(index).unwrap()),
            children.get(index).unwrap()))
        index = index + 1
    }
    if h_pattern_kind(source) == 4 {
        h_pattern_struct(h_pattern_plan_struct_owner(source), rebuilt)
    } else if h_pattern_kind(source) == 5 {
        h_pattern_variant(h_pattern_plan_variant(source), rebuilt)
    } else {
        panic("PreCore closure: projected pattern has wrong plan kind")
    }
}

fn expand_pattern(pattern: Pattern, plan: HPatternPlan) -> List<ClosedPattern> {
    match pattern {
        Pattern::OrPattern { patterns, .. } => {
            if h_pattern_kind(plan) != 6 {
                panic("PreCore closure: OrPattern exact plan is absent")
            }
            let plans = h_pattern_plan_children(plan)
            if patterns.len() != plans.len() {
                panic("PreCore closure: OrPattern plan census differs")
            }
            let mut result: List<ClosedPattern> = []
            let mut index = 0
            while index < patterns.len() {
                for value in expand_pattern(
                        patterns.get(index).unwrap(),
                        plans.get(index).unwrap()) {
                    result.push(value)
                }
                index = index + 1
            }
            result
        },
        Pattern::TuplePattern { elements, span } => {
            if h_pattern_kind(plan) != 3 {
                panic("PreCore closure: tuple pattern plan differs")
            }
            expand_pattern_sequence(
                elements, h_pattern_plan_children(plan)).map(fn(sequence) {
                    ClosedPattern {
                        pattern: Pattern::TuplePattern {
                            elements: sequence.patterns, span: span
                        },
                        plan: h_pattern_tuple(sequence.plans)
                    }
                })
        },
        Pattern::Constructor { name, qualifier, fields, span } => {
            let plans = h_pattern_plan_fields(plan).map(
                fn(field) { h_pattern_field_pattern(field) })
            expand_pattern_sequence(fields, plans).map(fn(sequence) {
                ClosedPattern {
                    pattern: Pattern::Constructor {
                        name: name, qualifier: qualifier,
                        fields: sequence.patterns, span: span
                    },
                    plan: projected_plan(plan, sequence.plans)
                }
            })
        },
        Pattern::NamedConstructor { name, qualifier, fields, rest, span } => {
            let mut source_patterns: List<Pattern> = []
            for field in fields { source_patterns.push(field.pattern) }
            let plans = h_pattern_plan_fields(plan).map(
                fn(field) { h_pattern_field_pattern(field) })
            let sequences = expand_pattern_sequence(source_patterns, plans)
            sequences.map(fn(sequence) {
                let mut rebuilt: List<NamedPatternField> = []
                let mut index = 0
                while index < fields.len() {
                    let source = fields.get(index).unwrap()
                    rebuilt.push(NamedPatternField {
                        name: source.name,
                        pattern: sequence.patterns.get(index).unwrap(),
                        span: source.span
                    })
                    index = index + 1
                }
                ClosedPattern {
                    pattern: Pattern::NamedConstructor {
                        name: name, qualifier: qualifier,
                        fields: rebuilt, rest: rest, span: span
                    },
                    plan: projected_plan(plan, sequence.plans)
                }
            })
        },
        Pattern::Wildcard { .. } => {
            if h_pattern_kind(plan) != 0 {
                panic("PreCore closure: wildcard pattern plan differs")
            }
            [ClosedPattern { pattern: pattern, plan: plan }]
        },
        Pattern::Binding { .. } => {
            if h_pattern_kind(plan) != 1 {
                panic("PreCore closure: binding pattern plan differs")
            }
            let _ = h_pattern_plan_binding(plan)
            [ClosedPattern { pattern: pattern, plan: plan }]
        },
        Pattern::Literal { .. } => {
            if h_pattern_kind(plan) != 2 {
                panic("PreCore closure: literal pattern plan differs")
            }
            [ClosedPattern { pattern: pattern, plan: plan }]
        }
    }
}

fn closed_pattern_bindings(plan: HPatternPlan) -> List<HPatternBinding> {
    match h_pattern_kind(plan) {
        0 | 2 => [],
        1 => [h_pattern_plan_binding(plan)],
        3 | 6 => {
            let mut result: List<HPatternBinding> = []
            for child in h_pattern_plan_children(plan) {
                for binding in closed_pattern_bindings(child) {
                    result.push(binding)
                }
            }
            result
        },
        4 | 5 => {
            let mut result: List<HPatternBinding> = []
            for field in h_pattern_plan_fields(plan) {
                for binding in closed_pattern_bindings(
                        h_pattern_field_pattern(field)) {
                    result.push(binding)
                }
            }
            result
        },
        _ => panic("PreCore closure: invalid exact pattern plan")
    }
}

fn close_arms(values: List<HMatchArm>) -> List<HMatchArm> {
    let mut result: List<HMatchArm> = []
    for arm in values {
        let plan = match arm.pattern_plan {
            some(value) => value,
            none => panic("PreCore closure: match arm exact pattern is absent")
        }
        let guard = close_optional_expr(arm.guard)
        let body = close_expr(arm.body)
        for expanded in expand_pattern(arm.pattern, plan) {
            result.push(HMatchArm {
                pattern: expanded.pattern, pattern_plan: some(expanded.plan),
                bindings: closed_pattern_bindings(expanded.plan),
                guard: guard, body: body, span: arm.span
            })
        }
    }
    result
}

fn close_string_interp(
    parts: List<HStringInterpPart>, plan: HStringInterpPlan,
    ty: Type, effects: EffectRow, span: Span
) -> HExpr {
    let builder_binder = h_string_interp_builder_binder(plan)
    let append_literal = h_string_interp_append_literal(plan)
    let append_value = h_string_interp_append_value(plan)
    let append_signature = exact_plan_signature(append_literal)
    let append_params = fn_parameter_types(append_signature)
    if append_params.len() < 1 {
        panic("PreCore closure: interpolation append has no receiver type")
    }
    let builder_type = append_params.get(0).unwrap()
    let builder_name = binder_name("$precore_string_builder", builder_binder)
    let builder = exact_call(
        h_string_interp_builder(plan), [], builder_type,
        EMPTY_ROW, span)
    let mut statements: List<HStmt> = [binder_let(
        builder_name, builder_binder, builder_type, builder, span)]
    let conversions = h_string_interp_value_to_string(plan)
    let mut expression_index = 0
    for part in parts {
        let (text, append_plan) = match part {
            HStringInterpPart::Literal(value) => (
                HExpr::StrLit {
                    value: value, ty: Type::StrType,
                    effects: EMPTY_ROW, span: span
                }, append_literal),
            HStringInterpPart::Expression(value) => {
                let closed = close_expr(value)
                let conversion = match conversions.get(expression_index) {
                    some(item) => item,
                    none => panic(
                        "PreCore closure: interpolation conversion plan is short")
                }
                expression_index = expression_index + 1
                let conversion_effects = merge_effect_rows(
                    hexpr_effects(closed), fn_effects(
                        exact_plan_signature(conversion)))
                (exact_call(
                    conversion, [closed], Type::StrType,
                    conversion_effects, span), append_value)
            }
        }
        let builder_read = binder_ident(
            builder_name, builder_binder, builder_type, span)
        let append_effects = merge_effect_rows(
            expression_list_effects([builder_read, text]),
            fn_effects(exact_plan_signature(append_plan)))
        statements.push(HStmt::ExprStmt {
            expr: exact_call(
                append_plan, [builder_read, text], Type::UnitType,
                append_effects, span),
            span: span
        })
    }
    if expression_index != conversions.len() {
        panic("PreCore closure: interpolation conversion plan is long")
    }
    let finish = h_string_interp_finish(plan)
    let finish_expr = exact_call(
        finish,
        [binder_ident(builder_name, builder_binder, builder_type, span)],
        ty, fn_effects(exact_plan_signature(finish)), span)
    HExpr::Block {
        stmts: statements, tail: some(finish_expr),
        ty: ty, effects: effects, span: span
    }
}

fn close_list_literal(
    elements: List<HExpr>, plan: HListLiteralPlan,
    ty: Type, effects: EffectRow, span: Span
) -> HExpr {
    let element_type = match ty {
        Type::StructType { type_params, .. } => match type_params.get(0) {
            some(value) => value,
            none => panic("PreCore closure: List has no element type")
        },
        _ => panic("PreCore closure: List literal type is not nominal")
    }
    let builder = h_list_literal_builder(plan)
    let builder_name = binder_name("$precore_list_builder", builder)
    let allocator = h_list_literal_allocator(plan)
    let allocator_signature = exact_plan_signature(allocator)
    let pointer_type = fn_result_type(allocator_signature)
    let allocator_expr = exact_call(
        allocator,
        [HExpr::IntLit { value: 0, ty: Type::IntType,
            effects: EMPTY_ROW, span: span }],
        pointer_type, fn_effects(allocator_signature), span)
    let constructor = h_list_literal_constructor(plan)
    let projections = h_constructor_fields(constructor)
    if projections.len() != 3 {
        panic("PreCore closure: List field census differs")
    }
    let mut fields: List<HNominalStructFieldInit> = []
    let values: List<HExpr> = [
        allocator_expr,
        HExpr::IntLit { value: 0, ty: Type::IntType,
            effects: EMPTY_ROW, span: span },
        HExpr::IntLit { value: 0, ty: Type::IntType,
            effects: EMPTY_ROW, span: span }
    ]
    let mut field_index = 0
    while field_index < projections.len() {
        let projection = projections.get(field_index).unwrap()
        if h_projection_kind(projection) != 0 {
            panic("PreCore closure: List field is not nominal")
        }
        let field = h_projection_nominal(projection)
        fields.push(HNominalStructFieldInit {
            name: nominal_field_ref_name(field), field_ref: field,
            field_index: nominal_field_ref_index(field),
            value: values.get(field_index).unwrap()
        })
        field_index = field_index + 1
    }
    let initial = HExpr::StructLit {
        name: match ty {
            Type::StructType { name, .. } => name,
            _ => panic("PreCore closure: List literal type changed")
        },
        owner_ref: h_list_literal_owner(plan), type_args: [],
        fields: fields, spread: none, constructor: some(constructor),
        ty: ty, effects: fn_effects(allocator_signature), span: span
    }
    let mut statements: List<HStmt> = [
        binder_let(builder_name, builder, ty, initial, span)
    ]
    let push = h_list_literal_push(plan)
    let push_signature = exact_plan_signature(push)
    let push_params = fn_parameter_types(push_signature)
    if push_params.len() != 2 ||
       !types_equal(push_params.get(0).unwrap(), ty) ||
       !types_equal(push_params.get(1).unwrap(), element_type) ||
       !types_equal(fn_result_type(push_signature), Type::UnitType) {
        panic("PreCore closure: List.push signature differs")
    }
    for element in elements {
        let closed = close_expr(element)
        let builder_read = binder_ident(
            builder_name, builder, ty, span)
        statements.push(HStmt::ExprStmt {
            expr: exact_call(
                push, [builder_read, closed], Type::UnitType,
                merge_effect_rows(
                    hexpr_effects(closed), fn_effects(push_signature)),
                span),
            span: span
        })
    }
    HExpr::Block {
        stmts: statements,
        tail: some(binder_ident(builder_name, builder, ty, span)),
        ty: ty, effects: effects, span: span
    }
}

fn close_index(
    receiver: HExpr, index: HExpr,
    call_plan: HExactCallPlan?, projection: HProjectionRef?,
    ty: Type, effects: EffectRow, span: Span
) -> HExpr {
    let closed_receiver = close_expr(receiver)
    let closed_index = close_expr(index)
    match (call_plan, projection) {
        (some(plan), some(exact_projection)) => {
            let _ = h_projection_kind(exact_projection)
            exact_call(
                plan, [closed_receiver, closed_index], ty, effects, span)
        },
        _ => panic("PreCore closure: IndexExpr exact plan is absent")
    }
}

fn unit_expr(span: Span) -> HExpr {
    HExpr::Block {
        stmts: [], tail: none, ty: Type::UnitType,
        effects: EMPTY_ROW, span: span
    }
}

fn prepend_statements(
    prefix: List<HStmt>, body: HExpr, span: Span
) -> HExpr {
    match body {
        HExpr::Block { stmts, tail, ty, effects, span: body_span } => {
            let mut combined: List<HStmt> = []
            for statement in prefix { combined.push(statement) }
            for statement in stmts { combined.push(statement) }
            HExpr::Block {
                stmts: combined, tail: tail, ty: ty,
                effects: effects, span: body_span
            }
        },
        _ => HExpr::Block {
            stmts: prefix, tail: some(body), ty: hexpr_type(body),
            effects: hexpr_effects(body), span: span
        }
    }
}

fn close_for_in(
    binding: Str, binding_span: Span, source_def_id: Int?,
    destructure: List<HForInDestructure>?, plan: HForInPlan,
    iterable: HExpr, body: HExpr, span: Span
) -> List<HStmt> {
    let binding_binder = h_for_in_binding_binder(plan)
    let range_binder = h_range_for_in_range_binder(plan)
    let counter_binder = h_range_for_in_counter_binder(plan)
    let finished_binder = h_range_for_in_finished_binder(plan)
    let range_name = binder_name("$precore_range", range_binder)
    let counter_name = binder_name("$precore_range_counter", counter_binder)
    let finished_name = binder_name(
        "$precore_range_finished", finished_binder)
    if source_def_id != some(binder_def_id(binding_binder)) {
        panic("PreCore closure: for binding DefId/plan differs")
    }
    if destructure.is_some() {
        panic("PreCore closure: Range item cannot be destructured")
    }
    let closed_iterable = close_expr(iterable)
    let range_type = hexpr_type(closed_iterable)
    let start = project_expr(
        binder_ident(range_name, range_binder, range_type, span),
        h_nominal_projection(h_range_for_in_start(plan)),
        Type::IntType, EMPTY_ROW, span)
    let inclusive = project_expr(
        binder_ident(range_name, range_binder, range_type, span),
        h_nominal_projection(h_range_for_in_inclusive(plan)),
        Type::BoolType, EMPTY_ROW, span)
    let order = h_range_for_in_order(plan)
    let less = HExpr::BinOp {
        op: BinOp::Lt,
        left: binder_ident(
            counter_name, counter_binder, Type::IntType, span),
        right: project_expr(
            binder_ident(range_name, range_binder, range_type, span),
            h_nominal_projection(h_range_for_in_end(plan)),
            Type::IntType, EMPTY_ROW, span),
        eq_dispatch: none, ord_dispatch: none,
        eq_plan: none, ord_plan: some(order), ty: Type::BoolType,
        effects: EMPTY_ROW, span: span
    }
    let less_equal = HExpr::BinOp {
        op: BinOp::Lte,
        left: binder_ident(
            counter_name, counter_binder, Type::IntType, span),
        right: project_expr(
            binder_ident(range_name, range_binder, range_type, span),
            h_nominal_projection(h_range_for_in_end(plan)),
            Type::IntType, EMPTY_ROW, span),
        eq_dispatch: none, ord_dispatch: none,
        eq_plan: none, ord_plan: some(order), ty: Type::BoolType,
        effects: EMPTY_ROW, span: span
    }
    let range_condition = HExpr::IfExpr {
        condition: inclusive,
        then_branch: HExpr::Block { stmts: [], tail: some(less_equal),
            ty: Type::BoolType, effects: EMPTY_ROW, span: span },
        else_branch: some(HExpr::Block { stmts: [], tail: some(less),
            ty: Type::BoolType, effects: EMPTY_ROW, span: span }),
        ty: Type::BoolType, effects: EMPTY_ROW, span: span
    }
    let condition = HExpr::IfExpr {
        condition: binder_ident(
            finished_name, finished_binder, Type::BoolType, span),
        then_branch: HExpr::Block { stmts: [], tail: some(HExpr::BoolLit {
            value: false, ty: Type::BoolType,
            effects: EMPTY_ROW, span: span }),
            ty: Type::BoolType, effects: EMPTY_ROW, span: span },
        else_branch: some(HExpr::Block { stmts: [],
            tail: some(range_condition), ty: Type::BoolType,
            effects: EMPTY_ROW, span: span }),
        ty: Type::BoolType, effects: EMPTY_ROW, span: span
    }
    // Advance before the source body after saving its visible binding, so
    // source `continue` naturally reaches the next value.  The inclusive end
    // marks completion instead of overflowing the maximum Int endpoint.
    let binding_init = binder_ident(
        counter_name, counter_binder, Type::IntType, span)
    let equality = h_range_for_in_equality(plan)
    let at_end = HExpr::BinOp {
        op: BinOp::Eq,
        left: binder_ident(
            counter_name, counter_binder, Type::IntType, span),
        right: project_expr(
            binder_ident(range_name, range_binder, range_type, span),
            h_nominal_projection(h_range_for_in_end(plan)),
            Type::IntType, EMPTY_ROW, span),
        eq_dispatch: none, ord_dispatch: none,
        eq_plan: some(equality), ord_plan: none, ty: Type::BoolType,
        effects: EMPTY_ROW, span: span
    }
    let inclusive_at_end = HExpr::IfExpr {
        condition: project_expr(
            binder_ident(range_name, range_binder, range_type, span),
            h_nominal_projection(h_range_for_in_inclusive(plan)),
            Type::BoolType, EMPTY_ROW, span),
        then_branch: HExpr::Block { stmts: [], tail: some(at_end),
            ty: Type::BoolType, effects: EMPTY_ROW, span: span },
        else_branch: some(HExpr::Block { stmts: [], tail: some(
            HExpr::BoolLit { value: false, ty: Type::BoolType,
                effects: EMPTY_ROW, span: span }),
            ty: Type::BoolType, effects: EMPTY_ROW, span: span }),
        ty: Type::BoolType, effects: EMPTY_ROW, span: span
    }
    let increment = HExpr::BinOp {
        op: BinOp::Add,
        left: binder_ident(
            counter_name, counter_binder, Type::IntType, span),
        right: HExpr::IntLit { value: 1, ty: Type::IntType,
            effects: EMPTY_ROW, span: span },
        eq_dispatch: none, ord_dispatch: none,
        eq_plan: none, ord_plan: none, ty: Type::IntType,
        effects: EMPTY_ROW, span: span
    }
    let advance = HExpr::IfExpr {
        condition: inclusive_at_end,
        then_branch: HExpr::Block { stmts: [HStmt::Assign {
            target: binder_ident(
                finished_name, finished_binder, Type::BoolType, span),
            value: HExpr::BoolLit { value: true, ty: Type::BoolType,
                effects: EMPTY_ROW, span: span }, span: span }],
            tail: none, ty: Type::UnitType,
            effects: EMPTY_ROW, span: span },
        else_branch: some(HExpr::Block { stmts: [HStmt::Assign {
            target: binder_ident(
                counter_name, counter_binder, Type::IntType, span),
            value: increment, span: span }],
            tail: none, ty: Type::UnitType,
            effects: EMPTY_ROW, span: span }),
        ty: Type::UnitType, effects: EMPTY_ROW, span: span
    }
    let prefix: List<HStmt> = [
        binder_let(
            binding, binding_binder, Type::IntType,
            binding_init, binding_span),
        HStmt::ExprStmt { expr: advance, span: span }
    ]
    let loop_body = prepend_statements(prefix, close_expr(body), span)
    [
        binder_let(
            range_name, range_binder, range_type,
            closed_iterable, span),
        binder_var(
            counter_name, counter_binder, Type::IntType, start, span),
        binder_var(
            finished_name, finished_binder, Type::BoolType,
            HExpr::BoolLit { value: false, ty: Type::BoolType,
                effects: EMPTY_ROW, span: span }, span),
        HStmt::While { condition: condition, body: loop_body, span: span }
    ]
}

fn close_expr_list(values: List<HExpr>) -> List<HExpr> {
    let mut result: List<HExpr> = []
    for value in values { result.push(close_expr(value)) }
    result
}

fn close_optional_expr(value: HExpr?) -> HExpr? {
    match value {
        some(item) => some(close_expr(item)),
        none => none
    }
}

fn close_decl_list(values: List<HDecl>) -> List<HDecl> {
    let mut result: List<HDecl> = []
    for value in values { result.push(close_decl(value)) }
    result
}

fn exact_trait_bounds(values: List<TraitBound>) -> List<TraitBound> {
    let mut result: List<TraitBound> = []
    let mut index = 0
    while index < values.len() {
        let value = values.get(index).unwrap()
        if value.dict_ordinal != index {
            panic("PreCore closure: dictionary bound order is not dense")
        }
        let mut right = index + 1
        while right < values.len() {
            if value.type_var_id == values.get(right).unwrap().type_var_id &&
               symbol_ref_same(
                    value.trait_ref,
                    values.get(right).unwrap().trait_ref) {
                panic("PreCore closure: trait bound identity is duplicated")
            }
            right = right + 1
        }
        result.push(value)
        index = index + 1
    }
    result
}

fn exact_h_type_params(values: List<HTypeParam>) -> List<HTypeParam> {
    let mut result: List<HTypeParam> = []
    for value in values {
        if value.type_var_id < 0 ||
           value.source.bounds.len() != value.bound_refs.len() {
            panic("PreCore closure: type parameter exact relation differs")
        }
        let mut index = 0
        while index < value.bound_refs.len() {
            let mut right = index + 1
            while right < value.bound_refs.len() {
                if symbol_ref_same(
                        value.bound_refs.get(index).unwrap(),
                        value.bound_refs.get(right).unwrap()) {
                    panic("PreCore closure: type parameter bound repeats")
                }
                right = right + 1
            }
            index = index + 1
        }
        result.push(value)
    }
    result
}

fn close_stmt(value: HStmt) -> List<HStmt> {
    match value {
        HStmt::Let { name, name_span, def_id, ty, init, span } => {
            match init {
                HExpr::DictConstruct { plan: some(exact), .. } => {
                    let result = h_dict_construct_result(exact)
                    if !slot_ref_is_source(result) ||
                       def_id != some(slot_ref_source_def_id(result)) {
                        panic(
                            "PreCore closure: dictionary result binder differs")
                    }
                },
                _ => {}
            }
            [HStmt::Let { name: name, name_span: name_span, def_id: def_id,
                ty: ty, init: close_expr(init), span: span }]
        },
        HStmt::Var { name, name_span, def_id, ty, init, span } => [
            HStmt::Var { name: name, name_span: name_span, def_id: def_id,
                ty: ty, init: close_expr(init), span: span }
        ],
        HStmt::Assign { target, value, span } => [HStmt::Assign {
            target: close_assignment_target(target),
            value: close_expr(value), span: span
        }],
        HStmt::ExprStmt { expr, span } => [HStmt::ExprStmt {
            expr: close_expr(expr), span: span
        }],
        HStmt::Return { value, span } => [HStmt::Return {
            value: close_optional_expr(value), span: span
        }],
        HStmt::While { condition, body, span } => [HStmt::While {
            condition: close_expr(condition), body: close_expr(body), span: span
        }],
        HStmt::ForIn {
            binding, binding_span, def_id, destructure, plan,
            iterable, body, span, ..
        } => close_for_in(
            binding, binding_span, def_id, destructure,
            match plan {
                some(value) => value,
                none => panic("PreCore closure: ForIn exact plan is absent")
            }, iterable, body, span),
        HStmt::Break { span } => [HStmt::Break { span: span }],
        HStmt::Continue { span } => [HStmt::Continue { span: span }],
        HStmt::LetDestructure {
            pattern, pattern_plan, bindings, init, span
        } => {
            let plan = match pattern_plan {
                some(value) => value,
                none => panic(
                    "PreCore closure: let destructure exact pattern is absent")
            }
            let expanded = expand_pattern(pattern, plan)
            if expanded.len() != 1 {
                panic("PreCore closure: let destructure is not irrefutable")
            }
            let mut exact_bindings: List<HLetDestructureBinding> = []
            for binding in bindings {
                if binding.projection.is_none() ||
                   (binding.name != "_" && binding.slot.is_none()) {
                    panic(
                        "PreCore closure: destructure exact projection/slot is absent")
                }
                exact_bindings.push(binding)
            }
            let exact = expanded.get(0).unwrap()
            // This is no longer a surface pattern operation: the carrier is a
            // deterministic ordered list of exact source SlotRef projections.
            // Keeping it atomic preserves one evaluation of `init` and keeps
            // every source binding visible to the following lexical statements.
            [HStmt::LetDestructure {
                pattern: exact.pattern, pattern_plan: some(exact.plan),
                bindings: exact_bindings, init: close_expr(init), span: span
            }]
        },
        HStmt::IfLet {
            pattern, pattern_plan, expr, then_block, else_block, span, ..
        } => {
            let plan = match pattern_plan {
                some(value) => value,
                none => panic("PreCore closure: IfLet exact pattern is absent")
            }
            let scrutinee = close_expr(expr)
            let then_body = close_expr(then_block)
            let else_body = match else_block {
                some(value) => close_expr(value),
                none => unit_expr(span)
            }
            let mut arms: List<HMatchArm> = []
            for expanded in expand_pattern(pattern, plan) {
                arms.push(HMatchArm {
                    pattern: expanded.pattern,
                    pattern_plan: some(expanded.plan),
                    bindings: closed_pattern_bindings(expanded.plan),
                    guard: none, body: then_body, span: span
                })
            }
            arms.push(HMatchArm {
                pattern: Pattern::Wildcard { span: span },
                pattern_plan: some(h_pattern_wildcard()), bindings: [],
                guard: none, body: else_body, span: span
            })
            let branch_effects = merge_effect_rows(
                hexpr_effects(then_body), hexpr_effects(else_body))
            let effects = merge_effect_rows(
                hexpr_effects(scrutinee), branch_effects)
            [HStmt::ExprStmt {
                expr: HExpr::MatchExpr {
                    scrutinee: scrutinee, arms: arms,
                    ty: Type::UnitType, effects: effects, span: span
                },
                span: span
            }]
        },
        HStmt::Drop { .. } =>
            panic("PreCore closure: resource Drop crossed semantic closure")
    }
}

fn close_block_statements(values: List<HStmt>) -> List<HStmt> {
    let mut result: List<HStmt> = []
    for value in values {
        for lowered in close_stmt(value) { result.push(lowered) }
    }
    result
}

fn close_captures(values: List<HLambdaCapture>) -> List<HLambdaCapture> {
    let mut result: List<HLambdaCapture> = []
    for capture in values {
        result.push(HLambdaCapture {
            source: capture.source, target: capture.target,
            value: close_optional_expr(capture.value),
            resource_site: capture.resource_site
        })
    }
    result
}

fn close_handlers(values: List<HEffectHandler>) -> List<HEffectHandler> {
    let mut result: List<HEffectHandler> = []
    for handler in values {
        match (handler.handled_ref, handler.operation_ref, handler.fail_ref) {
            (some(effect_ref), some(operation_ref), none) => {
                let _ = effect_ref
                let _ = operation_ref
            },
            (none, none, some(fail_ref)) => if
                h_fail_operation_tag(fail_ref) != 0 ||
                handler.params.len() != 1 {
                panic("PreCore closure: invalid dedicated fail handler")
            },
            _ => panic("PreCore closure: handler exact identity is ambiguous")
        }
        result.push(HEffectHandler {
            effect_name: handler.effect_name,
            handled_ref: handler.handled_ref,
            operation_ref: handler.operation_ref,
            fail_ref: handler.fail_ref,
            executable_ref: handler.executable_ref,
            captures: close_captures(handler.captures),
            handled_evidence_bindings: handler.handled_evidence_bindings,
            evidence_captures: handler.evidence_captures,
            op_name: handler.op_name, params: handler.params,
            resume_binding: handler.resume_binding,
            body: close_expr(handler.body)
        })
    }
    result
}

fn close_handle_expr(
    body: HExpr, handlers: List<HEffectHandler>,
    installed_evidence: List<HandledEvidenceRef>,
    ty: Type, effects: EffectRow, span: Span
) -> HExpr {
    let mut custom_effects: List<HandledEffectRef> = []
    for handler in handlers {
        match handler.handled_ref {
            some(effect_ref) => if !custom_effects.any(fn(existing) {
                    handled_effect_ref_same(existing, effect_ref) }) {
                custom_effects.push(effect_ref)
            },
            none => {}
        }
    }
    if custom_effects.len() != installed_evidence.len() {
        panic("PreCore closure: handled installation census differs")
    }
    let mut index = 0
    while index < installed_evidence.len() {
        if !handled_effect_ref_same(
                custom_effects.get(index).unwrap(),
                handled_evidence_requirement(
                    installed_evidence.get(index).unwrap())) {
            panic("PreCore closure: handled installation order differs")
        }
        index = index + 1
    }
    HExpr::HandleExpr {
        body: close_expr(body), handlers: close_handlers(handlers),
        installed_evidence: installed_evidence,
        ty: ty, effects: effects, span: span
    }
}

fn close_assignment_target(value: HExpr) -> HExpr {
    match value {
        HExpr::Ident { .. } => close_expr(value),
        HExpr::FieldAccess {
            receiver, field, access_kind, projection, ty, effects, span
        } => {
            if projection.is_none() {
                panic("PreCore closure: assignment field projection is absent")
            }
            HExpr::FieldAccess {
                receiver: close_expr(receiver), field: field,
                access_kind: access_kind, projection: projection,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::IndexExpr {
            ..
        } => panic("PreCore closure: indexed assignment has no 0.1 place plan"),
        _ => panic("PreCore closure: assignment target is not an exact place")
    }
}

fn close_expr(value: HExpr) -> HExpr {
    match value {
        HExpr::IntLit { value, ty, effects, span } =>
            HExpr::IntLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::FloatLit { value, ty, effects, span } =>
            HExpr::FloatLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::StrLit { value, ty, effects, span } =>
            HExpr::StrLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::BoolLit { value, ty, effects, span } =>
            HExpr::BoolLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::Ident {
            name, resolved_name, def_id, source_slot, callee_identity,
            dict_closure_dicts, ty, effects, span
        } => {
            if source_slot.is_none() && callee_identity.is_none() {
                panic("PreCore closure: identifier exact identity is absent")
            }
            HExpr::Ident {
                name: name, resolved_name: resolved_name, def_id: def_id,
                source_slot: source_slot, callee_identity: callee_identity,
                dict_closure_dicts: dict_closure_dicts,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::BinOp {
            op, left, right, eq_dispatch, ord_dispatch,
            eq_plan, ord_plan, ty, effects, span
        } => {
            match op {
                BinOp::Eq | BinOp::Neq => if eq_plan.is_none() {
                    panic("PreCore closure: equality operator exact plan is absent")
                },
                BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte =>
                    if ord_plan.is_none() {
                        panic("PreCore closure: ordering operator exact plan is absent")
                    },
                _ => if eq_plan.is_some() || ord_plan.is_some() {
                    panic("PreCore closure: primitive operator carries exact plan")
                }
            }
            HExpr::BinOp {
                op: op, left: close_expr(left), right: close_expr(right),
                eq_dispatch: none, ord_dispatch: none,
                eq_plan: eq_plan, ord_plan: ord_plan,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::UnaryOp { op, operand, ty, effects, span } => HExpr::UnaryOp {
            op: op, operand: close_expr(operand),
            ty: ty, effects: effects, span: span
        },
        HExpr::Call {
            callee, args, type_args, resolved_dicts, handled_evidence,
            callee_ref, method_ref, system_host, ty, effects, span
        } => {
            match (callee_ref, method_ref, system_host) {
                (none, some(_), none) => {},
                (some(_), none, none) => {},
                (some(exact_callee), none, some(host)) => {
                    if handled_evidence.len() != 0 {
                        panic("PreCore closure: system call entered handled evidence")
                    }
                    let host_executable = system_host_callable_executable(host)
                    if !callee_ref_is_named(exact_callee) ||
                       !executable_ref_is_named(host_executable) ||
                       !symbol_ref_same(
                            callee_ref_named_symbol(exact_callee),
                            executable_ref_named_symbol(host_executable)) {
                        panic("PreCore closure: system call exact callee differs")
                    }
                    let expected_effect = system_host_callable_effect(host)
                    let mut found = false
                    for atom in effects.effects {
                        match atom {
                            Effect::SystemEffect { reference } => if
                                system_effect_ref_same(reference, expected_effect) {
                                found = true
                            },
                            _ => {}
                        }
                    }
                    if !found {
                        panic("PreCore closure: system capability is absent")
                    }
                },
                _ => panic("PreCore closure: call identity domains overlap/absent")
            }
            HExpr::Call {
                callee: close_expr(callee),
                args: close_expr_list(args),
                type_args: type_args, resolved_dicts: resolved_dicts,
                handled_evidence: handled_evidence,
                callee_ref: callee_ref, method_ref: method_ref,
                system_host: system_host,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::FieldAccess {
            receiver, field, access_kind, projection, ty, effects, span
        } => {
            match access_kind {
                HFieldAccessKind::Method => {},
                _ => if projection.is_none() {
                    panic("PreCore closure: field exact projection is absent")
                }
            }
            HExpr::FieldAccess {
                receiver: close_expr(receiver), field: field,
                access_kind: access_kind, projection: projection,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::StructLit {
            name, owner_ref, type_args, fields, spread, constructor,
            ty, effects, span
        } => {
            let exact = match constructor {
                some(value) => value,
                none => panic("PreCore closure: struct constructor is absent")
            }
            let projections = h_constructor_fields(exact)
            if h_constructor_kind(exact) != 2 ||
               projections.len() != fields.len() {
                panic("PreCore closure: struct constructor plan differs")
            }
            let mut index = 0
            while index < fields.len() {
                if h_projection_kind(projections.get(index).unwrap()) != 0 ||
                   !nominal_field_ref_same(
                        h_projection_nominal(projections.get(index).unwrap()),
                        fields.get(index).unwrap().field_ref) {
                    panic("PreCore closure: struct field projection order differs")
                }
                index = index + 1
            }
            HExpr::StructLit {
                name: name, owner_ref: owner_ref, type_args: type_args,
                fields: fields.map(fn(field) { HNominalStructFieldInit {
                name: field.name, field_ref: field.field_ref,
                field_index: field.field_index,
                value: close_expr(field.value)
                } }),
                spread: close_optional_expr(spread),
                constructor: some(exact),
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::NamedVariantConstruct {
            enum_name, variant_name, variant_ref, fields, spread, constructor,
            ty, effects, span
        } => {
            let exact = match constructor {
                some(value) => value,
                none => panic("PreCore closure: variant constructor is absent")
            }
            if h_constructor_kind(exact) != 0 ||
               h_constructor_fields(exact).len() != fields.len() {
                panic("PreCore closure: variant constructor plan differs")
            }
            let projections = h_constructor_fields(exact)
            let mut index = 0
            while index < fields.len() {
                if h_projection_kind(projections.get(index).unwrap()) != 1 ||
                   !variant_field_ref_same(
                        h_projection_variant(projections.get(index).unwrap()),
                        fields.get(index).unwrap().field_ref) {
                    panic("PreCore closure: variant field projection order differs")
                }
                index = index + 1
            }
            HExpr::NamedVariantConstruct {
                enum_name: enum_name, variant_name: variant_name,
                variant_ref: variant_ref,
                fields: fields.map(fn(field) { HStructFieldInit {
                    name: field.name, field_ref: field.field_ref,
                    value: close_expr(field.value)
                } }),
                spread: close_optional_expr(spread),
                constructor: some(exact),
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } =>
            HExpr::MatchExpr {
                scrutinee: close_expr(scrutinee), arms: close_arms(arms),
                ty: ty, effects: effects, span: span
            },
        HExpr::Block { stmts, tail, ty, effects, span } => HExpr::Block {
            stmts: close_block_statements(stmts),
            tail: close_optional_expr(tail),
            ty: ty, effects: effects, span: span
        },
        HExpr::IfExpr {
            condition, then_branch, else_branch, ty, effects, span
        } => HExpr::IfExpr {
            condition: close_expr(condition), then_branch: close_expr(then_branch),
            else_branch: close_optional_expr(else_branch),
            ty: ty, effects: effects, span: span
        },
        HExpr::StringInterp { parts, plan, ty, effects, span } =>
            close_string_interp(parts, match plan {
                some(value) => value,
                none => panic(
                    "PreCore closure: StringInterp exact plan is absent")
            }, ty, effects, span),
        HExpr::TryCatch { body, arms, ty, effects, span } => HExpr::TryCatch {
            body: close_expr(body), arms: close_arms(arms),
            ty: ty, effects: effects, span: span
        },
        HExpr::HandleExpr {
            body, handlers, installed_evidence, ty, effects, span
        } => close_handle_expr(
            body, handlers, installed_evidence, ty, effects, span),
        HExpr::Lambda {
            executable_ref, params, captures,
            handled_evidence_bindings, evidence_captures, return_type,
            body, ty, effects, span
        } => HExpr::Lambda {
            executable_ref: executable_ref, params: params,
            captures: close_captures(captures),
            handled_evidence_bindings: handled_evidence_bindings,
            evidence_captures: evidence_captures,
            return_type: return_type, body: close_expr(body),
            ty: ty, effects: effects, span: span
        },
        HExpr::EffectOp {
            effect_name, op_name, operation_ref, fail_ref,
            handled_evidence, args, ty, effects, span
        } => {
            match (operation_ref, fail_ref) {
                (some(operation), none) => {
                    if handled_evidence.len() != 1 ||
                       !handled_effect_ref_same(
                            handled_evidence_requirement(
                                handled_evidence.get(0).unwrap()),
                            effect_operation_ref_effect(operation)) {
                        panic("PreCore closure: custom effect evidence differs")
                    }
                },
                (none, some(reference)) => if
                    h_fail_operation_tag(reference) != 0 ||
                    !contains_fail_effect(effects) || args.len() != 1 ||
                    handled_evidence.len() != 0 {
                    panic("PreCore closure: fail operation contract differs")
                },
                _ => panic("PreCore closure: effect operation identity is absent")
            }
            HExpr::EffectOp {
                effect_name: effect_name, op_name: op_name,
                operation_ref: operation_ref,
                fail_ref: fail_ref,
                handled_evidence: handled_evidence,
                args: close_expr_list(args),
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::ListLit { elements, plan, ty, effects, span } =>
            close_list_literal(elements, match plan {
                some(value) => value,
                none => panic("PreCore closure: List exact plan is absent")
            }, ty, effects, span),
        HExpr::TupleLit { elements, constructor, ty, effects, span } => {
            let exact = match constructor {
                some(value) => value,
                none => panic("PreCore closure: Tuple constructor is absent")
            }
            if h_constructor_kind(exact) != 1 ||
               h_constructor_tuple_arity(exact) != elements.len() {
                panic("PreCore closure: Tuple structural constructor differs")
            }
            HExpr::TupleLit {
                elements: close_expr_list(elements),
                constructor: some(exact), ty: ty,
                effects: effects, span: span
            }
        },
        HExpr::IndexExpr {
            receiver, index, call_plan, projection, ty, effects, span
        } => close_index(
            receiver, index, call_plan, projection, ty, effects, span),
        HExpr::DictConstruct {
            base_dict, plan, inner, ty, effects, span
        } => {
            let exact = match plan {
                some(value) => value,
                none => panic(
                    "PreCore closure: dictionary constructor is absent")
            }
            let exact_inner = h_dict_construct_inner(exact)
            if exact_inner.len() != inner.len() {
                panic("PreCore closure: dictionary evidence arity differs")
            }
            let mut index = 0
            while index < inner.len() {
                if !dict_ref_same(
                        exact_inner.get(index).unwrap(),
                        dict_ref_exact(inner.get(index).unwrap())) {
                    panic("PreCore closure: dictionary evidence order differs")
                }
                index = index + 1
            }
            let wrapped = make_wrapped_dict_ref(
                base_dict, h_dict_construct_trait(exact), inner,
                make_exact_wrapped_dict_ref(
                    h_dict_construct_base(exact), exact_inner))
            executable_call(
                h_dict_construct_executable(exact), Type::FnType {
                    params: [], return_type: ty, effects: EMPTY_ROW
                }, [], [wrapped],
                ty, effects, span)
        },
        HExpr::Clone { .. } =>
            panic("PreCore closure: legacy resource Clone crossed semantic closure"),
        HExpr::Take { .. } =>
            panic("PreCore closure: resource Take crossed semantic closure"),
        HExpr::ReturnExpr { value, ty, effects, span } => HExpr::ReturnExpr {
            value: close_optional_expr(value),
            ty: ty, effects: effects, span: span
        },
        HExpr::UnsafeBlock { body, ty, effects, span } => HExpr::UnsafeBlock {
            body: close_expr(body), ty: ty, effects: effects, span: span
        }
    }
}

fn close_decl(value: HDecl) -> HDecl {
    match value {
        HDecl::Fn {
            name, def_id, executable_ref, impl_method_ref,
            type_params, params, return_type, effects,
            handled_evidence_bindings, body, is_pub, trait_bounds, span
        } => HDecl::Fn {
            name: name, def_id: def_id, executable_ref: executable_ref,
            impl_method_ref: impl_method_ref,
            type_params: exact_h_type_params(type_params),
            params: params, return_type: return_type, effects: effects,
            handled_evidence_bindings: handled_evidence_bindings,
            body: close_expr(body), is_pub: is_pub,
            trait_bounds: exact_trait_bounds(trait_bounds), span: span
        },
        HDecl::Struct {
            name, owner_ref, type_params, fields, is_pub, span
        } => HDecl::Struct {
            name: name, owner_ref: owner_ref,
            type_params: exact_h_type_params(type_params),
            fields: fields, is_pub: is_pub, span: span
        },
        HDecl::Enum {
            name, owner_ref, type_params, variants, is_pub, span
        } => HDecl::Enum {
            name: name, owner_ref: owner_ref,
            type_params: exact_h_type_params(type_params),
            variants: variants, is_pub: is_pub, span: span
        },
        HDecl::Impl {
            target_type, target_ty, owner_ref, provider_ref, trait_ref,
            delegate_plan, default_specializations,
            type_params, trait_name, methods, assoc_types, span
        } => {
            let is_delegate = impl_provider_kind_same(
                impl_provider_ref_kind(provider_ref),
                impl_provider_kind_delegate())
            if is_delegate != delegate_plan.is_some() {
                panic("PreCore closure: delegate provider/plan presence differs")
            }
            HDecl::Impl {
                target_type: target_type, target_ty: target_ty,
                owner_ref: owner_ref,
                provider_ref: provider_ref, trait_ref: trait_ref,
                delegate_plan: delegate_plan,
                default_specializations: default_specializations,
                type_params: exact_h_type_params(type_params),
                trait_name: trait_name,
                methods: close_decl_list(methods),
                assoc_types: assoc_types, span: span
            }
        },
        HDecl::Effect {
            name, owner_ref, handled_ref, type_params, ops, is_pub, span
        } => HDecl::Effect {
            name: name, owner_ref: owner_ref, handled_ref: handled_ref,
            type_params: exact_h_type_params(type_params),
            ops: ops.map(fn(op) { HEffectOp {
                name: op.name, operation_ref: op.operation_ref,
                params: op.params, return_type: op.return_type
            } }),
            is_pub: is_pub, span: span
        },
        HDecl::Test {
            description, executable_ref, handled_evidence_bindings, body, span
        } => HDecl::Test {
            description: description, executable_ref: executable_ref,
            handled_evidence_bindings: handled_evidence_bindings,
            body: close_expr(body), span: span
        },
        HDecl::Trait {
            name, owner_ref, type_params, methods, supertraits,
            assoc_types, is_pub, span
        } => HDecl::Trait {
            name: name, owner_ref: owner_ref,
            type_params: exact_h_type_params(type_params),
            methods: methods.map(fn(method) { HTraitMethod {
                name: method.name, method_ref: method.method_ref,
                params: method.params, return_type: method.return_type,
                effects: method.effects, has_default: method.has_default,
                executable_ref: method.executable_ref,
                handled_evidence_bindings:
                    method.handled_evidence_bindings,
                body: close_optional_expr(method.body)
            } }),
            supertraits: supertraits, assoc_types: assoc_types,
            is_pub: is_pub, span: span
        },
        HDecl::ExternFn {
            name, abi_name, def_id, executable_ref, type_params,
            params, return_type, effects, resource_contract,
            handled_evidence_bindings,
            trait_bounds, is_pub, span
        } => HDecl::ExternFn {
            name: name, abi_name: abi_name, def_id: def_id,
            executable_ref: executable_ref,
            type_params: exact_h_type_params(type_params),
            params: params, return_type: return_type, effects: effects,
            resource_contract: resource_contract,
            handled_evidence_bindings: handled_evidence_bindings,
            trait_bounds: exact_trait_bounds(trait_bounds),
            is_pub: is_pub, span: span
        },
        HDecl::ExternType { name, type_params, is_pub, span } =>
            HDecl::ExternType {
                name: name, type_params: exact_h_type_params(type_params),
                is_pub: is_pub, span: span
            },
        HDecl::TypeAlias { name, owner_ref, ty, is_pub, span } => HDecl::TypeAlias {
            name: name, owner_ref: owner_ref, ty: ty,
            is_pub: is_pub, span: span
        },
        HDecl::Const {
            name, def_id, executable_ref, handled_evidence_bindings,
            ty, init, is_pub, span
        } => HDecl::Const {
            name: name, def_id: def_id, executable_ref: executable_ref,
            handled_evidence_bindings: handled_evidence_bindings,
            ty: ty, init: close_expr(init), is_pub: is_pub, span: span
        },
        HDecl::ModBlock { name, decls, is_pub, span } => HDecl::ModBlock {
            name: name, decls: close_decl_list(decls),
            is_pub: is_pub, span: span
        }
    }
}

pub fn close_hir_surface(program: HProgram, env: TypeEnv) -> HProgram {
    // Exact lookup is intentionally absent here. `env` is accepted so the
    // pipeline boundary remains explicit; every consumed authority is already
    // frozen on HIR by inference/registry producers.
    let _ = env
    let result = HProgram {
        decls: close_decl_list(program.decls),
        derived_impls: program.derived_impls,
        boxed_vars: program.boxed_vars,
        static_dicts: program.static_dicts,
        extern_type_names: program.extern_type_names,
        drop_types: program.drop_types
    }
    validate_hir_binder_def_ids(result)
    result
}
