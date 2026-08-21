pub const BUILTIN_INT: Str = "Int"
pub const BUILTIN_FLOAT: Str = "Float"
pub const BUILTIN_STR: Str = "Str"
pub const BUILTIN_BOOL: Str = "Bool"
pub const BUILTIN_RANGE: Str = "Range"
pub const BUILTIN_LIST: Str = "List"
pub const BUILTIN_MAP: Str = "Map"
pub const BUILTIN_SET: Str = "Set"
pub const BUILTIN_OPTION: Str = "Option"
pub const BUILTIN_CELL: Str = "Cell"
pub const BUILTIN_STRING_BUILDER: Str = "StringBuilder"
pub const BUILTIN_PTR: Str = "Ptr"

pub struct StructField {
    pub name: Str,
    pub ty: Type,
    pub is_pub: Bool
}

pub struct EnumVariant {
    pub name: Str,
    pub fields: List<Type>,
    pub field_names: List<Str>?
}

pub struct RecordField {
    pub name: Str,
    pub ty: Type
}

// A′ S1 shadow schema.  These values are transported and validated but have no
// semantic consumer until the later atomic activation commit.
pub const PARAM_OWNERSHIP_BORROW: Int = 0
pub const PARAM_OWNERSHIP_MUT_BORROW: Int = 1
pub const PARAM_OWNERSHIP_MOVE: Int = 2
pub const PARAM_OWNERSHIP_UNKNOWN: Int = 3

pub const RETURN_OWNERSHIP_OWNED: Int = 0
pub const RETURN_OWNERSHIP_BORROWED: Int = 1
pub const RETURN_OWNERSHIP_UNKNOWN: Int = 2

pub const CALLABLE_RESULT_ROLE_NONE: Int = 0
pub const CALLABLE_RESULT_ROLE_FRESH_OWNED_SLOT: Int = 1
pub const CALLABLE_RESULT_ROLE_UNKNOWN: Int = 2

pub const CALLABLE_SOURCE_BODY_INFERRED: Int = 0
pub const CALLABLE_SOURCE_DECLARED: Int = 1
pub const CALLABLE_SOURCE_BUILTIN: Int = 2
pub const CALLABLE_SOURCE_CONSERVATIVE_INTERFACE: Int = 3
pub const CALLABLE_SOURCE_ALIAS: Int = 4
pub const CALLABLE_SOURCE_SYNTHETIC: Int = 5

pub const CALLABLE_BORROW_OWNED: Int = 0
pub const CALLABLE_MOVE_OWNED: Int = 1
pub const CALLABLE_UNKNOWN: Int = 2
pub const CALLABLE_FIRST_MUT_BORROW_OWNED: Int = 3
pub const CALLABLE_BORROW_BORROWED: Int = 4
pub const CALLABLE_MUT_MOVE_OWNED: Int = 5
pub const CALLABLE_BORROW_MOVE_BORROWED: Int = 6
pub const CALLABLE_MOVE_BORROW_OWNED: Int = 7
pub const CALLABLE_BORROW_MUT_BORROW_OWNED: Int = 8
pub const CALLABLE_MUT_BORROW_MOVE_OWNED: Int = 9
pub const CALLABLE_SLOT_MOVE_OWNED: Int = 10
pub const CALLABLE_DYNAMIC_TERM_BASE: Int = 11
pub const CALLABLE_DYNAMIC_TERM_LIMIT: Int = 4000000000000000000

pub struct CallableOwnershipDescriptor {
    pub prefix_params: List<Int>,
    pub rest_param: Int,
    pub result: Int
}

// FORCE is carried independently from the public Borrow/MutBorrow/Move mode.
// `force_params[i] == false` means an inferred OWNING edge.
pub struct CallableTransferLevel {
    pub ownership_term: Int,
    pub force_params: List<Bool>
}

pub struct CallableOwnershipState {
    pub source: Int,
    pub arity: Int,
    pub producer_def_id: Int?,
    pub transfer_levels: List<CallableTransferLevel>
}

pub struct OwnershipShape {
    pub direct_drop: Bool,
    pub may_own: Bool,
    pub param_deps: List<Bool>
}

pub struct OwnershipMetadata {
    pub callable_descriptors: Map<Int, CallableOwnershipDescriptor>,
    pub callable_by_def_id: Map<Int, Int>,
    pub callable_state_by_def_id: Map<Int, CallableOwnershipState>,
    pub callable_result_role_by_def_id: Map<Int, Int>,
    pub returned_callable_result_role_by_def_id: Map<Int, Int>,
    pub ownership_shapes: Map<Str, OwnershipShape>,
    // Disjoint from env.ids.next_def_id: shadow inference must not perturb I′.
    pub next_ownership_term: Int
}

pub fn new_ownership_metadata() -> OwnershipMetadata {
    OwnershipMetadata {
        callable_descriptors: map_new(),
        callable_by_def_id: map_new(),
        callable_state_by_def_id: map_new(),
        callable_result_role_by_def_id: map_new(),
        returned_callable_result_role_by_def_id: map_new(),
        ownership_shapes: map_new(),
        next_ownership_term: CALLABLE_DYNAMIC_TERM_BASE
    }
}

pub fn fresh_ownership_term(mut metadata: OwnershipMetadata) -> Int {
    let result = metadata.next_ownership_term
    if result < CALLABLE_DYNAMIC_TERM_BASE ||
       result >= CALLABLE_DYNAMIC_TERM_LIMIT {
        panic("unreachable: shadow ownership term namespace exhausted")
    }
    metadata.next_ownership_term = result + 1
    result
}

pub fn shadow_callable_param_ownership(
    metadata: OwnershipMetadata, ownership_term: Int, index: Int
) -> Int {
    if ownership_term == CALLABLE_BORROW_OWNED ||
       ownership_term == CALLABLE_BORROW_BORROWED {
        return PARAM_OWNERSHIP_BORROW
    }
    if ownership_term == CALLABLE_MOVE_OWNED {
        return PARAM_OWNERSHIP_MOVE
    }
    if ownership_term == CALLABLE_FIRST_MUT_BORROW_OWNED {
        return if index == 0 {
            PARAM_OWNERSHIP_MUT_BORROW
        } else {
            PARAM_OWNERSHIP_BORROW
        }
    }
    if ownership_term == CALLABLE_MUT_MOVE_OWNED {
        if index == 0 { return PARAM_OWNERSHIP_MUT_BORROW }
        if index == 1 { return PARAM_OWNERSHIP_MOVE }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_BORROW_MOVE_BORROWED {
        if index == 0 { return PARAM_OWNERSHIP_BORROW }
        if index == 1 { return PARAM_OWNERSHIP_MOVE }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_MOVE_BORROW_OWNED {
        if index == 0 { return PARAM_OWNERSHIP_MOVE }
        if index == 1 { return PARAM_OWNERSHIP_BORROW }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_BORROW_MUT_BORROW_OWNED {
        if index == 0 || index == 2 { return PARAM_OWNERSHIP_BORROW }
        if index == 1 { return PARAM_OWNERSHIP_MUT_BORROW }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_MUT_BORROW_MOVE_OWNED {
        if index == 0 { return PARAM_OWNERSHIP_MUT_BORROW }
        if index == 1 { return PARAM_OWNERSHIP_BORROW }
        if index == 2 { return PARAM_OWNERSHIP_MOVE }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_SLOT_MOVE_OWNED {
        if index == 0 || index == 2 {
            return PARAM_OWNERSHIP_MUT_BORROW
        }
        if index == 1 || index == 3 || index == 4 {
            return PARAM_OWNERSHIP_BORROW
        }
        return PARAM_OWNERSHIP_UNKNOWN
    }
    match metadata.callable_descriptors.get(ownership_term) {
        some(descriptor) => match descriptor.prefix_params.get(index) {
            some(mode) => mode,
            none => if descriptor.rest_param >= 0 {
                descriptor.rest_param
            } else {
                PARAM_OWNERSHIP_UNKNOWN
            }
        },
        none => PARAM_OWNERSHIP_UNKNOWN
    }
}

pub fn shadow_callable_return_ownership(
    metadata: OwnershipMetadata, ownership_term: Int
) -> Int {
    if ownership_term == CALLABLE_UNKNOWN {
        return RETURN_OWNERSHIP_UNKNOWN
    }
    if ownership_term == CALLABLE_BORROW_BORROWED ||
       ownership_term == CALLABLE_BORROW_MOVE_BORROWED {
        return RETURN_OWNERSHIP_BORROWED
    }
    if ownership_term >= CALLABLE_BORROW_OWNED &&
       ownership_term < CALLABLE_DYNAMIC_TERM_BASE {
        return RETURN_OWNERSHIP_OWNED
    }
    match metadata.callable_descriptors.get(ownership_term) {
        some(descriptor) => descriptor.result,
        none => RETURN_OWNERSHIP_UNKNOWN
    }
}

pub fn shadow_callable_term_for_def_id(
    metadata: OwnershipMetadata, def_id: Int
) -> Int {
    metadata.callable_by_def_id.get(def_id).unwrap_or(CALLABLE_UNKNOWN)
}

fn valid_param_ownership(mode: Int) -> Bool {
    mode >= PARAM_OWNERSHIP_BORROW && mode <= PARAM_OWNERSHIP_UNKNOWN
}

fn valid_return_ownership(mode: Int) -> Bool {
    mode >= RETURN_OWNERSHIP_OWNED && mode <= RETURN_OWNERSHIP_UNKNOWN
}

pub fn normalize_callable_ownership_descriptor(
    descriptor: CallableOwnershipDescriptor
) -> CallableOwnershipDescriptor {
    if descriptor.rest_param < -1 ||
       (descriptor.rest_param >= 0 &&
        !valid_param_ownership(descriptor.rest_param)) {
        panic("unreachable: invalid shadow callable rest ownership")
    }
    if !valid_return_ownership(descriptor.result) {
        panic("unreachable: invalid shadow callable return ownership")
    }
    for mode in descriptor.prefix_params {
        if !valid_param_ownership(mode) {
            panic("unreachable: invalid shadow callable parameter ownership")
        }
    }
    descriptor
}

pub fn record_shadow_callable(
    mut metadata: OwnershipMetadata, def_id: Int, ownership_term: Int,
    source: Int, arity: Int, producer_def_id: Int?,
    force_params: List<Bool>
) {
    if def_id == -1 || arity < 0 ||
       (ownership_term < 0 &&
        !metadata.callable_descriptors.contains_key(ownership_term)) ||
       force_params.len() != arity ||
       source < CALLABLE_SOURCE_BODY_INFERRED ||
       source > CALLABLE_SOURCE_SYNTHETIC {
        panic("unreachable: invalid shadow callable identity")
    }
    match metadata.callable_state_by_def_id.get(def_id) {
        some(existing) => {
            let existing_level = match existing.transfer_levels.first() {
                some(level) => level,
                none => panic("unreachable: existing shadow callable has no transfer level")
            }
            let mut forces_match = existing_level.force_params.len() ==
                force_params.len()
            let mut force_index = 0
            while forces_match && force_index < force_params.len() {
                if existing_level.force_params.get(force_index) !=
                   force_params.get(force_index) {
                    forces_match = false
                }
                force_index = force_index + 1
            }
            if existing.arity != arity ||
               existing.source != source ||
               existing.producer_def_id != producer_def_id ||
               existing_level.ownership_term != ownership_term ||
               !forces_match ||
               metadata.callable_by_def_id.get(def_id) !=
                    some(ownership_term) {
                panic("unreachable: conflicting exact shadow callable contract")
            }
        },
        none => {
            metadata.callable_by_def_id.insert(def_id, ownership_term)
            metadata.callable_state_by_def_id.insert(def_id,
                CallableOwnershipState {
                    source: source, arity: arity,
                    producer_def_id: producer_def_id,
                    transfer_levels: [CallableTransferLevel {
                        ownership_term: ownership_term,
                        force_params: force_params
                    }]
                })
            metadata.callable_result_role_by_def_id.insert(
                def_id, CALLABLE_RESULT_ROLE_UNKNOWN)
            metadata.returned_callable_result_role_by_def_id.insert(
                def_id, CALLABLE_RESULT_ROLE_UNKNOWN)
        }
    }
}

// Narrow exact-identity override for a registration that becomes trusted only
// after provenance resolution (currently prelude runtime bridges).  It never
// changes the DefId and is not a name-based consumer API.
pub fn replace_shadow_callable(
    mut metadata: OwnershipMetadata, def_id: Int, ownership_term: Int,
    source: Int, arity: Int, producer_def_id: Int?,
    force_params: List<Bool>
) {
    if def_id == -1 || arity < 0 || force_params.len() != arity ||
       source < CALLABLE_SOURCE_BODY_INFERRED ||
       source > CALLABLE_SOURCE_SYNTHETIC ||
       (ownership_term < 0 &&
        !metadata.callable_descriptors.contains_key(ownership_term)) {
        panic("unreachable: invalid exact shadow callable override")
    }
    metadata.callable_by_def_id.insert(def_id, ownership_term)
    metadata.callable_state_by_def_id.insert(def_id,
        CallableOwnershipState {
            source: source, arity: arity,
            producer_def_id: producer_def_id,
            transfer_levels: [CallableTransferLevel {
                ownership_term: ownership_term,
                force_params: force_params
            }]
        })
    if !metadata.callable_result_role_by_def_id.contains_key(def_id) {
        metadata.callable_result_role_by_def_id.insert(
            def_id, CALLABLE_RESULT_ROLE_UNKNOWN)
    }
    if !metadata.returned_callable_result_role_by_def_id.contains_key(def_id) {
        metadata.returned_callable_result_role_by_def_id.insert(
            def_id, CALLABLE_RESULT_ROLE_UNKNOWN)
    }
}

pub fn set_shadow_callable_result_role(
    mut metadata: OwnershipMetadata, def_id: Int, role: Int
) {
    if role < CALLABLE_RESULT_ROLE_NONE ||
       role > CALLABLE_RESULT_ROLE_UNKNOWN ||
       !metadata.callable_by_def_id.contains_key(def_id) {
        panic("unreachable: invalid shadow callable result role")
    }
    metadata.callable_result_role_by_def_id.insert(def_id, role)
}

pub fn validate_shadow_ownership_metadata(metadata: OwnershipMetadata) {
    if metadata.next_ownership_term < CALLABLE_DYNAMIC_TERM_BASE ||
       metadata.next_ownership_term > CALLABLE_DYNAMIC_TERM_LIMIT {
        panic("unreachable: shadow ownership counter regressed")
    }
    for entry in metadata.callable_by_def_id.entries() {
        let (def_id, term) = entry
        if (term < 0 && !metadata.callable_descriptors.contains_key(term)) ||
           !metadata.callable_state_by_def_id.contains_key(def_id) ||
           !metadata.callable_result_role_by_def_id.contains_key(def_id) ||
           !metadata.returned_callable_result_role_by_def_id.contains_key(def_id) {
            panic("unreachable: incomplete exact shadow callable metadata")
        }
        match metadata.callable_state_by_def_id.get(def_id) {
            some(state) => {
                if state.source < CALLABLE_SOURCE_BODY_INFERRED ||
                   state.source > CALLABLE_SOURCE_SYNTHETIC ||
                   state.arity < 0 || state.transfer_levels.len() != 1 {
                    panic("unreachable: invalid exact shadow callable state")
                }
                match state.transfer_levels.first() {
                    some(level) => {
                        if level.ownership_term != term ||
                           level.force_params.len() != state.arity {
                            panic("unreachable: invalid shadow transfer level")
                        }
                    },
                    none => panic("unreachable: missing shadow transfer level")
                }
            },
            none => panic("unreachable: missing exact shadow callable state")
        }
        let result_role = metadata.callable_result_role_by_def_id.get(
            def_id).unwrap_or(CALLABLE_RESULT_ROLE_UNKNOWN)
        let returned_role = metadata.returned_callable_result_role_by_def_id.get(
            def_id).unwrap_or(CALLABLE_RESULT_ROLE_UNKNOWN)
        if result_role < CALLABLE_RESULT_ROLE_NONE ||
           result_role > CALLABLE_RESULT_ROLE_UNKNOWN ||
           returned_role < CALLABLE_RESULT_ROLE_NONE ||
           returned_role > CALLABLE_RESULT_ROLE_UNKNOWN {
            panic("unreachable: invalid shadow callable result role")
        }
    }
    for entry in metadata.callable_state_by_def_id.entries() {
        let (def_id, _) = entry
        if !metadata.callable_by_def_id.contains_key(def_id) {
            panic("unreachable: orphan shadow callable state")
        }
    }
    for entry in metadata.callable_result_role_by_def_id.entries() {
        let (def_id, _) = entry
        if !metadata.callable_by_def_id.contains_key(def_id) {
            panic("unreachable: orphan shadow callable result role")
        }
    }
    for entry in metadata.returned_callable_result_role_by_def_id.entries() {
        let (def_id, _) = entry
        if !metadata.callable_by_def_id.contains_key(def_id) {
            panic("unreachable: orphan returned callable result role")
        }
    }
    for entry in metadata.callable_descriptors.entries() {
        let (_, descriptor) = entry
        let _ = normalize_callable_ownership_descriptor(descriptor)
    }
    for entry in metadata.ownership_shapes.entries() {
        let (_, shape) = entry
        if shape.direct_drop && !shape.may_own {
            panic("unreachable: direct Drop shadow shape does not own")
        }
    }
}

pub fn clone_shadow_callable_identity(
    mut metadata: OwnershipMetadata, old_def_id: Int, new_def_id: Int,
    remapped_producer_def_id: Int?
) {
    let term = match metadata.callable_by_def_id.get(old_def_id) {
        some(value) => value,
        none => panic("unreachable: cloned callable identity has no contract")
    }
    let state = match metadata.callable_state_by_def_id.get(old_def_id) {
        some(value) => value,
        none => panic("unreachable: cloned callable identity has no state")
    }
    let level = match state.transfer_levels.first() {
        some(value) => value,
        none => panic("unreachable: cloned callable identity has no transfer level")
    }
    let mut forces: List<Bool> = []
    for force in level.force_params { forces.push(force) }
    record_shadow_callable(
        metadata, new_def_id, term, state.source, state.arity,
        remapped_producer_def_id, forces)
    match metadata.callable_result_role_by_def_id.get(old_def_id) {
        some(role) => metadata.callable_result_role_by_def_id.insert(
            new_def_id, role),
        none => {}
    }
    match metadata.returned_callable_result_role_by_def_id.get(old_def_id) {
        some(role) => metadata.returned_callable_result_role_by_def_id.insert(
            new_def_id, role),
        none => {}
    }
}

pub enum Type {
    IntType,
    FloatType,
    StrType,
    BoolType,
    UnitType,
    NeverType,
    AnyType,
    TypeVar { id: Int, name: Str? },
    FnType { params: List<Type>, return_type: Type, effects: EffectRow,
             ownership_term: Int },
    StructType { name: Str, type_params: List<Type> },
    EnumType { name: Str, type_params: List<Type> },
    GenericType { base: Type, args: List<Type> },
    RecordType { fields: List<RecordField>, tail: Int?, tail_name: Str? },
    EffectRowType { effects: List<Effect>, tail: Int? },
    TupleType { elements: List<Type> },
    PtrType { pointee: Type },
    ErrorType
}

pub fn callable_ownership_term(ty: Type) -> Int? {
    match ty {
        Type::FnType { ownership_term, .. } => some(ownership_term),
        _ => none
    }
}

pub fn with_callable_ownership_term(ty: Type, term: Int) -> Type {
    match ty {
        Type::FnType { params, return_type, effects, .. } => Type::FnType {
            params: params, return_type: return_type, effects: effects,
            ownership_term: term
        },
        _ => ty
    }
}

pub enum Effect {
    IoEffect,
    FailEffect { error_type: Type },
    MutEffect { state_type: Type },
    CustomEffect { name: Str, type_args: List<Type> },
    UnsafeEffect
}

pub struct EffectRow {
    pub effects: List<Effect>,
    pub tail: Int?
}

pub struct RowMergeResult {
    pub row: EffectRow,
    pub tails_to_unify: Option<(Int, Int)>
}

pub const INT: Type = Type::IntType
pub const FLOAT: Type = Type::FloatType
pub const STR: Type = Type::StrType
pub const BOOL: Type = Type::BoolType
pub const UNIT: Type = Type::UnitType
pub const NEVER: Type = Type::NeverType
pub const ANY: Type = Type::AnyType

pub const EMPTY_ROW: EffectRow = EffectRow { effects: [], tail: none }

pub fn effect_kind_name(e: Effect) -> Str {
    match e {
        Effect::IoEffect => "io",
        Effect::MutEffect { .. } => "mut",
        Effect::FailEffect { .. } => "fail",
        Effect::CustomEffect { name, .. } => name,
        Effect::UnsafeEffect => "unsafe"
    }
}

fn is_type_var(t: Type) -> Bool {
    match t { Type::TypeVar { .. } => true, _ => false }
}

pub fn effects_match_kind(a: Effect, b: Effect) -> Bool {
    match a {
        Effect::IoEffect => match b { Effect::IoEffect => true, _ => false },
        // is_type_var fallback: during row_merge, type vars may not yet be resolved.
        // Without this, mut<?T> and mut<Int> (where ?T will resolve to Int) would be
        // kept as separate effects. The broader match ensures deduplication in row_merge;
        // effects_same_kind (used elsewhere) requires exact type equality for stricter checks.
        Effect::MutEffect { state_type: sa } => match b {
            Effect::MutEffect { state_type: sb } => is_type_var(sa) || is_type_var(sb) || types_equal(sa, sb),
            _ => false
        },
        // Intentional: all FailEffects match regardless of error type parameter.
        // Ring uses single-fail-effect design — the unification engine separately
        // handles error type parameter merging during row unification.
        Effect::FailEffect { .. } => match b { Effect::FailEffect { .. } => true, _ => false },
        Effect::CustomEffect { name: na, .. } => match b {
            Effect::CustomEffect { name: nb, .. } => na == nb,
            _ => false
        },
        Effect::UnsafeEffect => match b { Effect::UnsafeEffect => true, _ => false }
    }
}

pub fn type_to_builtin_name(t: Type) -> Str? {
    match t {
        Type::IntType => some(BUILTIN_INT),
        Type::FloatType => some(BUILTIN_FLOAT),
        Type::StrType => some(BUILTIN_STR),
        Type::BoolType => some(BUILTIN_BOOL),
        Type::UnitType => some("Unit"),
        Type::PtrType { .. } => some(BUILTIN_PTR),
        Type::StructType { name, .. } => some(name),
        Type::EnumType { name, .. } => some(name),
        Type::ErrorType => none,
        _ => none
    }
}

pub fn make_option_type(inner: Type) -> Type {
    Type::EnumType {
        name: BUILTIN_OPTION,
        type_params: [inner]
    }
}

pub fn is_option_type(t: Type) -> Bool {
    match t {
        Type::EnumType { name, type_params, .. } =>
            name == BUILTIN_OPTION && type_params.len() == 1,
        _ => false
    }
}

pub fn option_inner(t: Type) -> Type {
    match t {
        Type::EnumType { type_params, .. } => type_params.first().unwrap_or(UNIT),
        _ => UNIT
    }
}

pub fn make_list_type(element: Type) -> Type {
    Type::StructType { name: BUILTIN_LIST, type_params: [element] }
}

pub fn is_list_type(t: Type) -> Bool {
    match t {
        Type::StructType { name, type_params, .. } => name == BUILTIN_LIST && type_params.len() == 1,
        _ => false
    }
}

pub fn list_element(t: Type) -> Type {
    match t {
        Type::StructType { type_params, .. } => type_params.first().unwrap_or(UNIT),
        _ => UNIT
    }
}

pub fn make_map_type(key: Type, value: Type) -> Type {
    Type::StructType { name: BUILTIN_MAP, type_params: [key, value] }
}

pub fn is_map_type(t: Type) -> Bool {
    match t {
        Type::StructType { name, type_params, .. } => name == BUILTIN_MAP && type_params.len() == 2,
        _ => false
    }
}

pub fn make_set_type(element: Type) -> Type {
    Type::StructType { name: BUILTIN_SET, type_params: [element] }
}

pub fn is_set_type(t: Type) -> Bool {
    match t {
        Type::StructType { name, type_params, .. } => name == BUILTIN_SET && type_params.len() == 1,
        _ => false
    }
}

pub fn effect_row(effects: List<Effect>) -> EffectRow {
    EffectRow { effects: effects, tail: none }
}

pub fn open_effect_row(effects: List<Effect>, tail: Int) -> EffectRow {
    EffectRow { effects: effects, tail: some(tail) }
}

pub fn row_contains(row: EffectRow, eff: Effect) -> Bool {
    row.effects.any(fn(e) { effects_equal(e, eff) })
}

pub fn effects_same_kind(a: Effect, b: Effect) -> Bool {
    match a {
        Effect::IoEffect => match b { Effect::IoEffect => true, _ => false },
        Effect::MutEffect { state_type: sa } => match b { Effect::MutEffect { state_type: sb } => types_equal(sa, sb), _ => false },
        Effect::FailEffect { error_type: ea } => match b {
            Effect::FailEffect { error_type: eb } => types_equal(ea, eb),
            _ => false
        },
        Effect::CustomEffect { name: na, .. } => match b {
            Effect::CustomEffect { name: nb, .. } => na == nb,
            _ => false
        },
        Effect::UnsafeEffect => match b { Effect::UnsafeEffect => true, _ => false }
    }
}

pub fn row_merge(a: EffectRow, b: EffectRow) -> RowMergeResult {
    let mut merged = list_clone(a.effects)
    for eff in b.effects {
        if !merged.any(fn(e) { effects_match_kind(e, eff) }) {
            merged.push(eff)
        }
    }
    let tail: Int? = match (a.tail, b.tail) {
        (some(ta), _) => some(ta),
        (_, some(tb)) => some(tb),
        _ => none
    }
    let tails_to_unify: Option<(Int, Int)> = match (a.tail, b.tail) {
        (some(ta), some(tb)) => if ta != tb { some((ta, tb)) } else { none },
        _ => none
    }
    RowMergeResult {
        row: EffectRow { effects: merged, tail: tail },
        tails_to_unify: tails_to_unify
    }
}

fn type_lists_equal(a: List<Type>, b: List<Type>) -> Bool {
    if a.len() != b.len() { return false }
    let mut i = 0
    while i < a.len() {
        if let some(x) = a.get(i) {
            if let some(y) = b.get(i) {
                if !types_equal(x, y) { return false }
            }
        }
        i = i + 1
    }
    true
}

fn effects_list_equal(a: List<Effect>, b: List<Effect>) -> Bool {
    if a.len() != b.len() { return false }
    let mut i = 0
    while i < a.len() {
        if let some(x) = a.get(i) {
            if let some(y) = b.get(i) {
                if !effects_equal(x, y) { return false }
            }
        }
        i = i + 1
    }
    true
}

fn optional_ids_equal(a: Int?, b: Int?) -> Bool {
    match (a, b) {
        (some(x), some(y)) => x == y,
        _ => a.is_none() && b.is_none()
    }
}

pub fn effects_equal(a: Effect, b: Effect) -> Bool {
    match a {
        Effect::IoEffect => match b { Effect::IoEffect => true, _ => false },
        Effect::MutEffect { state_type: sa } => match b {
            Effect::MutEffect { state_type: sb } => types_equal(sa, sb),
            _ => false
        },
        Effect::FailEffect { error_type: et_a } => match b {
            Effect::FailEffect { error_type: et_b } => types_equal(et_a, et_b),
            _ => false
        },
        Effect::CustomEffect { name: na, type_args: args_a } => match b {
            Effect::CustomEffect { name: nb, type_args: args_b } =>
                na == nb && type_lists_equal(args_a, args_b),
            _ => false
        },
        Effect::UnsafeEffect => match b { Effect::UnsafeEffect => true, _ => false }
    }
}

pub fn types_equal(a: Type, b: Type) -> Bool {
    match a {
        Type::IntType => match b { Type::IntType => true, _ => false },
        Type::FloatType => match b { Type::FloatType => true, _ => false },
        Type::StrType => match b { Type::StrType => true, _ => false },
        Type::BoolType => match b { Type::BoolType => true, _ => false },
        Type::UnitType => match b { Type::UnitType => true, _ => false },
        Type::NeverType => match b { Type::NeverType => true, _ => false },
        Type::AnyType => match b { Type::AnyType => true, _ => false },
        Type::ErrorType => match b { Type::ErrorType => true, _ => false },
        Type::TypeVar { id: id_a, .. } => match b {
            Type::TypeVar { id: id_b, .. } => id_a == id_b,
            _ => false
        },
        Type::FnType { params: pa, return_type: ra, effects: ea, .. } => match b {
            Type::FnType { params: pb, return_type: rb, effects: eb, .. } =>
                type_lists_equal(pa, pb) && types_equal(ra, rb)
                    && effects_list_equal(ea.effects, eb.effects)
                    // Open effect row tails are compared by exact TypeVar ID (structural equality).
                    // Two different open tails (?N1, ?N2) are structurally distinct even though both
                    // represent "open row" semantically. Semantic equivalence is handled by unification,
                    // not types_equal — this function is for error messages and debug output.
                    && optional_ids_equal(ea.tail, eb.tail),
            _ => false
        },
        Type::StructType { name: na, type_params: tpa, .. } => match b {
            Type::StructType { name: nb, type_params: tpb, .. } =>
                na == nb && type_lists_equal(tpa, tpb),
            _ => false
        },
        Type::EnumType { name: na, type_params: tpa, .. } => match b {
            Type::EnumType { name: nb, type_params: tpb, .. } =>
                na == nb && type_lists_equal(tpa, tpb),
            _ => false
        },
        Type::GenericType { base: ba, args: aa } => match b {
            Type::GenericType { base: bb, args: ab } =>
                types_equal(ba, bb) && type_lists_equal(aa, ab),
            _ => false
        },
        // Record fields are compared as unordered sets (row polymorphism semantics).
        // Field order does not affect type equality, unlike TupleType where position matters.
        Type::RecordType { fields: fa, tail: ta, .. } => match b {
            Type::RecordType { fields: fb, tail: tb, .. } => {
                if fa.len() != fb.len() { return false }
                if !optional_ids_equal(ta, tb) { return false }
                fa.all(fn(f) {
                    fb.any(fn(bf) { bf.name == f.name && types_equal(f.ty, bf.ty) })
                })
            },
            _ => false
        },
        Type::EffectRowType { effects: ea, tail: ta } => match b {
            Type::EffectRowType { effects: eb, tail: tb } => {
                if !optional_ids_equal(ta, tb) { return false }
                if ea.len() != eb.len() { return false }
                ea.all(fn(ae) { eb.any(fn(be) { effects_equal(ae, be) }) })
            },
            _ => false
        },
        Type::TupleType { elements: ea } => match b {
            Type::TupleType { elements: eb } => type_lists_equal(ea, eb),
            _ => false
        },
        Type::PtrType { pointee: pa } => match b {
            Type::PtrType { pointee: pb } => types_equal(pa, pb),
            _ => false
        }
    }
}

// Convert the compiler's canonical module identity back to source spelling.
// This is shared by every user-facing type/effect/trait diagnostic so the
// internal `$$_` separator never leaks through error messages.
pub fn nominal_display_name(identity: Str) -> Str {
    identity.replace("$$_", "::").replace("$", "::")
}

pub fn type_to_string(t: Type) -> Str {
    match t {
        Type::IntType => BUILTIN_INT,
        Type::FloatType => BUILTIN_FLOAT,
        Type::StrType => BUILTIN_STR,
        Type::BoolType => BUILTIN_BOOL,
        Type::UnitType => "()",
        Type::NeverType => "Never",
        Type::AnyType => "Any",
        Type::TypeVar { name, id } => match name {
            some(n) => n,
            none => "?${id.to_str()}"
        },
        Type::FnType { params, return_type, effects, .. } => {
            let ps = params.map(fn(p) { type_to_string(p) }).join(", ")
            let ret = type_to_string(return_type)
            let eff = effect_row_to_string(effects)
            if eff.len() > 0 { "(${ps}) -> ${ret} / ${eff}" }
            else { "(${ps}) -> ${ret}" }
        },
        Type::StructType { name, type_params, .. } => {
            let display = nominal_display_name(name)
            if type_params.len() == 0 { display }
            else { "${display}<${type_params.map(fn(p) { type_to_string(p) }).join(", ")}>" }
        },
        Type::EnumType { name, type_params, .. } => {
            let display = nominal_display_name(name)
            if name == BUILTIN_OPTION && type_params.len() == 1 {
                "${type_to_string(type_params.first().unwrap_or(UNIT))}?"
            } else if type_params.len() == 0 { display }
            else { "${display}<${type_params.map(fn(p) { type_to_string(p) }).join(", ")}>" }
        },
        Type::GenericType { base, args } => {
            "${type_to_string(base)}<${args.map(fn(a) { type_to_string(a) }).join(", ")}>"
        },
        Type::RecordType { fields, tail, tail_name } => {
            let fs = fields.map(fn(f) { "${f.name}: ${type_to_string(f.ty)}" }).join(", ")
            match tail {
                some(t) => {
                    let ts = match tail_name { some(n) => n, none => "?${t.to_str()}" }
                    if fs.len() > 0 { "{${fs}, ..${ts}}" } else { "{..${ts}}" }
                },
                none => "{${fs}}"
            }
        },
        Type::EffectRowType { effects, tail } => {
            let es = effects.map(fn(e) { effect_to_string(e) }).join(", ")
            match tail {
                some(t) => "<${es}, ?${t.to_str()}>",
                none => "<${es}>"
            }
        },
        Type::TupleType { elements } =>
            "(${elements.map(fn(e) { type_to_string(e) }).join(", ")})",
        Type::PtrType { pointee } =>
            "Ptr<${type_to_string(pointee)}>",
        Type::ErrorType => "<error>"
    }
}

pub fn effect_to_string(e: Effect) -> Str {
    match e {
        Effect::IoEffect => "io",
        Effect::MutEffect { state_type } => "mut<${type_to_string(state_type)}>",
        Effect::FailEffect { error_type } => "fail<${type_to_string(error_type)}>",
        Effect::CustomEffect { name, type_args } => {
            let display = nominal_display_name(name)
            if type_args.len() == 0 { display }
            else { "${display}<${type_args.map(fn(a) { type_to_string(a) }).join(", ")}>" }
        },
        Effect::UnsafeEffect => "unsafe"
    }
}

pub fn effect_row_to_string(row: EffectRow) -> Str {
    if row.effects.len() == 0 && row.tail.is_none() { return "" }
    let mut parts = row.effects.map(fn(e) { effect_to_string(e) })
    match row.tail {
        some(t) => parts.push("?${t.to_str()}"),
        none => {}
    }
    parts.join(", ")
}
