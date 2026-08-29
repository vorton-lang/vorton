// Sole typed manifest for compiler-owned 0.1 extern bridges with ownership
// semantics that differ from an ordinary top-level extern declaration.
//
// Resolver source sites are related once, during prelude registration, to a
// fixed CompilerExternRef and its ExecutableRef/resource contract. HIR and
// Core copy those typed facts unchanged. Runtime names and source spellings
// are deliberately absent from this module.

use ir_identity::{SymbolRef, CompilerExternSite, CompilerExternRef,
    SystemEffectRef,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind, symbol_ref_declaration_site_path,
    namespace_kind_same, namespace_value, make_symbol_ref,
    compiler_extern_site_from_tag, compiler_extern_site_tag,
    compiler_extern_site_same,
    compiler_extern_ref_for_site, compiler_extern_ref_symbol,
    compiler_extern_ref_site, compiler_extern_ref_same,
    prelude_extern_symbol,
    system_effect_console, system_effect_fs, system_effect_process,
    system_effect_ref_same,
    COMPILER_EXTERN_SLOT_ALLOC, COMPILER_EXTERN_SLOT_DEALLOC,
    COMPILER_EXTERN_SLOT_READ, COMPILER_EXTERN_SLOT_TAKE,
    COMPILER_EXTERN_SLOT_WRITE, COMPILER_EXTERN_SLOT_REPLACE,
    COMPILER_EXTERN_SLOT_SWAP, COMPILER_EXTERN_SLOT_MOVE,
    COMPILER_EXTERN_SLOT_DROP, COMPILER_EXTERN_LIST_SORT,
    COMPILER_EXTERN_SITE_COUNT}
use ir_inventory::{ExecutableRef, SystemHostCallableRef,
    CallableResourceContractFact,
    CallableResourceRoleFact,
    make_named_executable_ref, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_same,
    make_system_host_callable_ref, system_host_callable_effect,
    system_host_callable_executable, system_host_callable_same,
    make_callable_resource_contract_fact,
    callable_resource_contract_parameter_roles,
    callable_resource_contract_same,
    callable_resource_role_read, callable_resource_role_mutate,
    callable_resource_role_consume, callable_resource_role_force}
use types::{Type, Effect, INT, STR, BOOL, UNIT, BUILTIN_LIST,
    EMPTY_ROW, types_equal, effects_equal}

pub const COMPILER_EXTERN_SOURCE_DELIVERY_COUNT: Int = 17
pub const HOST_IMPORT_SOURCE_DELIVERY_COUNT: Int = 12

pub const HOST_IMPORT_BOXED_DIRECT: Int = 0
pub const HOST_IMPORT_PRINT_VALUE: Int = 1
pub const HOST_IMPORT_ASSERT_CONDITION: Int = 2
const HOST_IMPORT_LOWERING_COUNT: Int = 3

pub struct HostImportLoweringTag { tag: Int }

fn host_import_lowering_tag_from_int(tag: Int) -> HostImportLoweringTag {
    if tag < HOST_IMPORT_BOXED_DIRECT || tag >= HOST_IMPORT_LOWERING_COUNT {
        panic("host import manifest: lowering tag is invalid")
    }
    HostImportLoweringTag { tag: tag }
}

pub fn host_import_lowering_tag(value: HostImportLoweringTag) -> Int {
    host_import_lowering_tag_from_int(value.tag).tag
}

struct CompilerExternSourceSite {
    origin_module_key: Str,
    declaration_site_path: Str
}

struct HostImportSourceDelivery {
    source_site: CompilerExternSourceSite,
    source_name: Str,
    system_effect: SystemEffectRef,
    native_target: Str,
    lowering: HostImportLoweringTag
}

struct HostImportSourceRegistration {
    delivery: HostImportSourceDelivery,
    source_symbol: SymbolRef,
    normalized_signature: Type,
    generic_arity: Int
}

pub struct HostImportFact {
    host: SystemHostCallableRef,
    callable_signature: Type,
    failure_effects: List<Effect>,
    native_target: Str,
    lowering: HostImportLoweringTag
}

struct CompilerExternSourceDelivery {
    source_site: CompilerExternSourceSite,
    compiler_site: CompilerExternSite,
    publish_hdecl: Bool
}

fn prelude_source_site(
    basename: Str, declaration_index: Int
) -> CompilerExternSourceSite {
    if basename == "" || declaration_index < 0 {
        panic("compiler extern manifest: invalid prelude source site")
    }
    CompilerExternSourceSite {
        origin_module_key: "$prelude$::${basename}",
        declaration_site_path: "frame:0|item:${declaration_index.to_str()}"
    }
}

fn host_source_delivery(
    basename: Str, declaration_index: Int, source_name: Str,
    system_effect: SystemEffectRef, native_target: Str, lowering_tag: Int
) -> HostImportSourceDelivery {
    if source_name == "" || native_target == "" {
        panic("host import manifest: source/native name is empty")
    }
    HostImportSourceDelivery {
        source_site: prelude_source_site(basename, declaration_index),
        source_name: source_name, system_effect: system_effect,
        native_target: native_target,
        lowering: host_import_lowering_tag_from_int(lowering_tag)
    }
}

fn host_import_source_deliveries() -> List<HostImportSourceDelivery> {
    let result = [
        host_source_delivery(
            "io", 0, "print", system_effect_console(),
            "ring_print", HOST_IMPORT_PRINT_VALUE),
        host_source_delivery(
            "io", 1, "assert", system_effect_console(),
            "ring_assert", HOST_IMPORT_ASSERT_CONDITION),
        host_source_delivery(
            "process", 2, "eprintln", system_effect_console(),
            "ring_eprintln", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "fs", 0, "read_file", system_effect_fs(),
            "ring_read_file", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "fs", 1, "write_file", system_effect_fs(),
            "ring_write_file", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "fs", 2, "file_exists", system_effect_fs(),
            "ring_file_exists", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "fs", 3, "delete_file", system_effect_fs(),
            "ring_delete_file", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "path", 1, "path_resolve", system_effect_fs(),
            "ring_path_resolve", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "process", 0, "argv", system_effect_process(),
            "ring_args", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "process", 1, "exit_process", system_effect_process(),
            "ring_exit", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "process", 3, "cwd", system_effect_process(),
            "ring_cwd", HOST_IMPORT_BOXED_DIRECT),
        host_source_delivery(
            "process", 4, "exec_sync", system_effect_process(),
            "exec_sync", HOST_IMPORT_BOXED_DIRECT)
    ]
    if result.len() != HOST_IMPORT_SOURCE_DELIVERY_COUNT {
        panic("host import manifest: fixed source census differs")
    }
    let mut boxed = 0
    let mut print_value = 0
    let mut assert_condition = 0
    for delivery in result {
        let tag = host_import_lowering_tag(delivery.lowering)
        if tag == HOST_IMPORT_BOXED_DIRECT { boxed = boxed + 1 }
        else if tag == HOST_IMPORT_PRINT_VALUE {
            print_value = print_value + 1
        } else if tag == HOST_IMPORT_ASSERT_CONDITION {
            assert_condition = assert_condition + 1
        } else {
            panic("host import manifest: fixed lowering tag is invalid")
        }
    }
    if boxed != 10 || print_value != 1 || assert_condition != 1 {
        panic("host import manifest: lowering census differs")
    }
    result
}

fn source_delivery(
    basename: Str, declaration_index: Int,
    compiler_tag: Int, publish_hdecl: Bool
) -> CompilerExternSourceDelivery {
    CompilerExternSourceDelivery {
        source_site: prelude_source_site(basename, declaration_index),
        compiler_site: compiler_extern_site_from_tag(compiler_tag),
        publish_hdecl: publish_hdecl
    }
}

// Exact source delivery is independent from publication. list/map both
// declare the seven shared slot bridges, so registration validates both
// declarations but only the final map owner publishes their HDecl contracts.
// list-only swap/move/sort publish directly. No later stage deduplicates.
fn compiler_extern_source_deliveries(
) -> List<CompilerExternSourceDelivery> {
    [
        source_delivery("list", 1, COMPILER_EXTERN_SLOT_ALLOC, false),
        source_delivery("list", 2, COMPILER_EXTERN_SLOT_DEALLOC, false),
        source_delivery("list", 3, COMPILER_EXTERN_SLOT_READ, false),
        source_delivery("list", 4, COMPILER_EXTERN_SLOT_TAKE, false),
        source_delivery("list", 5, COMPILER_EXTERN_SLOT_WRITE, false),
        source_delivery("list", 6, COMPILER_EXTERN_SLOT_REPLACE, false),
        source_delivery("list", 7, COMPILER_EXTERN_SLOT_SWAP, true),
        source_delivery("list", 8, COMPILER_EXTERN_SLOT_MOVE, true),
        source_delivery("list", 9, COMPILER_EXTERN_SLOT_DROP, false),
        source_delivery("list", 10, COMPILER_EXTERN_LIST_SORT, true),
        source_delivery("map", 1, COMPILER_EXTERN_SLOT_ALLOC, true),
        source_delivery("map", 2, COMPILER_EXTERN_SLOT_DEALLOC, true),
        source_delivery("map", 3, COMPILER_EXTERN_SLOT_READ, true),
        source_delivery("map", 4, COMPILER_EXTERN_SLOT_TAKE, true),
        source_delivery("map", 5, COMPILER_EXTERN_SLOT_WRITE, true),
        source_delivery("map", 6, COMPILER_EXTERN_SLOT_REPLACE, true),
        source_delivery("map", 7, COMPILER_EXTERN_SLOT_DROP, true)
    ]
}

fn source_symbol_matches_site(
    source: SymbolRef, site: CompilerExternSourceSite
) -> Bool {
    namespace_kind_same(
        symbol_ref_namespace_kind(source), namespace_value()) &&
        symbol_ref_origin_module_key(source) == site.origin_module_key &&
        symbol_ref_declaration_site_path(source) ==
            site.declaration_site_path
}

fn source_sites_same(
    left: CompilerExternSourceSite, right: CompilerExternSourceSite
) -> Bool {
    left.origin_module_key == right.origin_module_key &&
        left.declaration_site_path == right.declaration_site_path
}

fn compiler_extern_delivery_for_source(
    source: SymbolRef
) -> CompilerExternSourceDelivery? {
    for delivery in compiler_extern_source_deliveries() {
        if source_symbol_matches_site(
                source, delivery.source_site) {
            return some(delivery)
        }
    }
    none
}

fn host_import_delivery_for_source(
    source: SymbolRef
) -> HostImportSourceDelivery? {
    for delivery in host_import_source_deliveries() {
        if source_symbol_matches_site(source, delivery.source_site) {
            return some(delivery)
        }
    }
    none
}

fn host_import_delivery_executable(
    delivery: HostImportSourceDelivery
) -> ExecutableRef {
    make_named_executable_ref(prelude_extern_symbol(delivery.source_name))
}

fn host_import_delivery_for_executable(
    executable: ExecutableRef
) -> HostImportSourceDelivery? {
    for delivery in host_import_source_deliveries() {
        if executable_ref_same(
                executable, host_import_delivery_executable(delivery)) {
            return some(delivery)
        }
    }
    none
}

struct HostImportEffectProjection {
    system_effect: SystemEffectRef?,
    failures: List<Effect>
}

fn host_import_effect_projection(
    signature: Type
) -> HostImportEffectProjection {
    let effects = match signature {
        Type::FnType { effects, .. } => effects,
        _ => panic("host import manifest: callable signature is not Fn")
    }
    let mut system_effect: SystemEffectRef? = none
    let mut failures: List<Effect> = []
    let mut invalid = effects.tail.is_some()
    for atom in effects.effects {
        match atom {
            Effect::SystemEffect { reference } => {
                if system_effect.is_some() { invalid = true }
                system_effect = some(reference)
            },
            Effect::FailEffect { .. } => failures.push(atom),
            _ => { invalid = true }
        }
    }
    if system_effect.is_some() && invalid {
        panic("host import manifest: system/failure effect subset differs")
    }
    HostImportEffectProjection {
        system_effect: system_effect, failures: failures
    }
}

fn host_failure_effects_same(
    left: List<Effect>, right: List<Effect>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if !effects_equal(
                left.get(index).unwrap(), right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn make_host_import_fact(
    executable: ExecutableRef, system_effect: SystemEffectRef,
    callable_signature: Type, failure_effects: List<Effect>,
    native_target: Str, lowering: HostImportLoweringTag
) -> HostImportFact {
    if !executable_ref_is_named(executable) || native_target == "" {
        panic("host import manifest: physical relation is incomplete")
    }
    let projection = host_import_effect_projection(callable_signature)
    match projection.system_effect {
        some(reference) => if !system_effect_ref_same(
                reference, system_effect) {
            panic("host import manifest: system capability differs")
        },
        none => panic("host import manifest: system capability is absent")
    }
    if !host_failure_effects_same(
            projection.failures, failure_effects) {
        panic("host import manifest: failure subset differs")
    }
    HostImportFact {
        host: make_system_host_callable_ref(system_effect, executable),
        callable_signature: callable_signature,
        failure_effects: failure_effects.map(fn(value) { value }),
        native_target: native_target,
        lowering: host_import_lowering_tag_from_int(
            host_import_lowering_tag(lowering))
    }
}

pub fn host_import_fact_for_extern(
    host: SystemHostCallableRef, raw_abi_name: Str,
    callable_signature: Type
) -> HostImportFact {
    let executable = system_host_callable_executable(host)
    let system_effect = system_host_callable_effect(host)
    let projection = host_import_effect_projection(callable_signature)
    match projection.system_effect {
        some(reference) => if !system_effect_ref_same(
                reference, system_effect) {
            panic("host import manifest: call capability differs")
        },
        none => panic("host import manifest: call has no system capability")
    }
    match host_import_delivery_for_executable(executable) {
        some(delivery) => {
            if raw_abi_name != delivery.source_name ||
               !system_effect_ref_same(
                    system_effect, delivery.system_effect) {
                panic("host import manifest: fixed source relation differs")
            }
            make_host_import_fact(
                executable, system_effect, callable_signature,
                projection.failures, delivery.native_target,
                delivery.lowering)
        },
        none => {
            if symbol_ref_origin_module_key(
                    executable_ref_named_symbol(executable)) ==
                    "$prelude$::extern" {
                panic("host import manifest: prelude host source is outside census")
            }
            if raw_abi_name == "" {
                panic("host import manifest: user host ABI name is empty")
            }
            make_host_import_fact(
                executable, system_effect, callable_signature,
                projection.failures, raw_abi_name,
                host_import_lowering_tag_from_int(
                    HOST_IMPORT_BOXED_DIRECT))
        }
    }
}

pub fn host_import_fact_for_declaration(
    executable: ExecutableRef, raw_abi_name: Str,
    callable_signature: Type
) -> HostImportFact? {
    let projection = host_import_effect_projection(callable_signature)
    match projection.system_effect {
        some(system_effect) => some(host_import_fact_for_extern(
            make_system_host_callable_ref(system_effect, executable),
            raw_abi_name, callable_signature)),
        none => none
    }
}

pub fn host_import_fact_host(value: HostImportFact) -> SystemHostCallableRef {
    value.host
}
pub fn host_import_fact_executable(value: HostImportFact) -> ExecutableRef {
    system_host_callable_executable(value.host)
}
pub fn host_import_fact_system_effect(
    value: HostImportFact
) -> SystemEffectRef { system_host_callable_effect(value.host) }
pub fn host_import_fact_callable_signature(value: HostImportFact) -> Type {
    value.callable_signature
}
pub fn host_import_fact_failure_effects(
    value: HostImportFact
) -> List<Effect> { value.failure_effects.map(fn(item) { item }) }
pub fn host_import_fact_native_target(value: HostImportFact) -> Str {
    value.native_target
}
pub fn host_import_fact_lowering(
    value: HostImportFact
) -> HostImportLoweringTag { value.lowering }

pub fn host_import_fact_same(
    left: HostImportFact, right: HostImportFact
) -> Bool {
    system_host_callable_same(left.host, right.host) &&
        types_equal(left.callable_signature, right.callable_signature) &&
        host_failure_effects_same(
            left.failure_effects, right.failure_effects) &&
        left.native_target == right.native_target &&
        host_import_lowering_tag(left.lowering) ==
            host_import_lowering_tag(right.lowering)
}

fn resource_contract(
    parameter_roles: List<CallableResourceRoleFact>,
    result_role: CallableResourceRoleFact,
    result_alias_ordinals: List<Int>
) -> CallableResourceContractFact {
    make_callable_resource_contract_fact(
        parameter_roles, result_role, result_alias_ordinals)
}

// Every site states all parameter roles, the result role, and an empty alias
// set explicitly. Even default-looking entries belong here so no downstream
// stage can recreate policy from a runtime/source spelling.
fn compiler_extern_resource_contract(
    site: CompilerExternSite
) -> CallableResourceContractFact {
    let tag = compiler_extern_site_tag(site)
    if tag == COMPILER_EXTERN_SLOT_ALLOC {
        return resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_DEALLOC {
        return resource_contract(
            [callable_resource_role_force(), callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_READ {
        return resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_TAKE {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_WRITE {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read(),
             callable_resource_role_consume()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_REPLACE {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_SWAP {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_MOVE {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read(),
             callable_resource_role_mutate(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_SLOT_DROP {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == COMPILER_EXTERN_LIST_SORT {
        return resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    panic("compiler extern manifest: resource census is incomplete")
}

pub struct CompilerExternManifestEntry {
    source_symbol: SymbolRef,
    intrinsic: CompilerExternRef,
    executable: ExecutableRef,
    resource: CallableResourceContractFact,
    normalized_signature: Type,
    generic_arity: Int,
    publish_hdecl: Bool
}

fn make_compiler_extern_manifest_entry(
    source_symbol: SymbolRef, delivery: CompilerExternSourceDelivery,
    normalized_signature: Type, generic_arity: Int
) -> CompilerExternManifestEntry {
    if !source_symbol_matches_site(
            source_symbol, delivery.source_site) {
        panic("compiler extern manifest: source relation drifted")
    }
    if generic_arity != 1 {
        panic("compiler extern manifest: bridge generic arity differs")
    }
    let intrinsic = compiler_extern_ref_for_site(delivery.compiler_site)
    let executable = make_named_executable_ref(
        compiler_extern_ref_symbol(intrinsic))
    let resource = compiler_extern_resource_contract(
        delivery.compiler_site)
    let signature_arity = match normalized_signature {
        Type::FnType { params, .. } => params.len(),
        _ => panic("compiler extern manifest: source signature is not callable")
    }
    if !executable_ref_is_named(executable) ||
       !symbol_ref_same(
            executable_ref_named_symbol(executable),
            compiler_extern_ref_symbol(intrinsic)) ||
       callable_resource_contract_parameter_roles(resource).len() !=
            signature_arity {
        panic("compiler extern manifest: typed relation is incomplete")
    }
    CompilerExternManifestEntry {
        source_symbol: source_symbol,
        intrinsic: intrinsic,
        executable: executable,
        resource: resource,
        normalized_signature: normalized_signature,
        generic_arity: generic_arity,
        publish_hdecl: delivery.publish_hdecl
    }
}

pub fn compiler_extern_manifest_entry_source(
    value: CompilerExternManifestEntry
) -> SymbolRef { value.source_symbol }

pub fn compiler_extern_manifest_entry_intrinsic(
    value: CompilerExternManifestEntry
) -> CompilerExternRef { value.intrinsic }

pub fn compiler_extern_manifest_entry_executable(
    value: CompilerExternManifestEntry
) -> ExecutableRef { value.executable }

pub fn compiler_extern_manifest_entry_resource(
    value: CompilerExternManifestEntry
) -> CallableResourceContractFact { value.resource }
pub fn compiler_extern_manifest_entry_normalized_signature(
    value: CompilerExternManifestEntry
) -> Type { value.normalized_signature }
pub fn compiler_extern_manifest_entry_generic_arity(
    value: CompilerExternManifestEntry
) -> Int { value.generic_arity }

pub fn compiler_extern_manifest_entry_compiler_symbol(
    value: CompilerExternManifestEntry
) -> SymbolRef { compiler_extern_ref_symbol(value.intrinsic) }

// Core parent selection consumes the same manifest relation by exact
// ExecutableRef. This is not a second resource lookup: the contract itself is
// already carried on HDecl, while this projection only keeps the fixed
// `$builtin` executable in its matching inventory domain.
pub fn compiler_extern_ref_for_executable(
    executable: ExecutableRef
) -> CompilerExternRef? {
    for tag in 0..COMPILER_EXTERN_SITE_COUNT {
        let intrinsic = compiler_extern_ref_for_site(
            compiler_extern_site_from_tag(tag))
        if executable_ref_same(
                executable, make_named_executable_ref(
                    compiler_extern_ref_symbol(intrinsic))) {
            return some(intrinsic)
        }
    }
    none
}

pub struct CompilerExternManifest {
    entries: List<CompilerExternManifestEntry>,
    host_sources: List<HostImportSourceRegistration>,
    closed: Bool
}

fn validate_compiler_extern_identity_canaries() {
    let source_site = prelude_source_site("map", 5)
    let before = make_symbol_ref(
        source_site.origin_module_key, namespace_value(),
        "internal-before-rename", source_site.declaration_site_path)
    let after = make_symbol_ref(
        source_site.origin_module_key, namespace_value(),
        "internal-after-rename", source_site.declaration_site_path)
    let signature = Type::FnType {
        params: [Type::IntType, Type::IntType, Type::IntType],
        return_type: Type::UnitType, effects: EMPTY_ROW
    }
    let before_entry = make_compiler_extern_manifest_entry(
        before, compiler_extern_delivery_for_source(before).unwrap(),
        signature, 1)
    let after_entry = make_compiler_extern_manifest_entry(
        after, compiler_extern_delivery_for_source(after).unwrap(),
        signature, 1)
    if !compiler_extern_ref_same(
            before_entry.intrinsic, after_entry.intrinsic) ||
       !executable_ref_same(
            before_entry.executable, after_entry.executable) {
        panic("compiler extern manifest: internal rename changed identity")
    }
    let unrelated = make_symbol_ref(
        "$single$::user", namespace_value(),
        "internal-before-rename", source_site.declaration_site_path)
    if compiler_extern_delivery_for_source(unrelated).is_some() {
        panic("compiler extern manifest: unrelated source acquired ownership")
    }
}

pub fn new_compiler_extern_manifest() -> CompilerExternManifest {
    validate_compiler_extern_identity_canaries()
    CompilerExternManifest {
        entries: [], host_sources: [], closed: false
    }
}

fn register_host_import_source(
    mut manifest: CompilerExternManifest, source: SymbolRef,
    delivery: HostImportSourceDelivery,
    normalized_signature: Type, generic_arity: Int
) {
    if !source_symbol_matches_site(source, delivery.source_site) {
        panic("host import manifest: source site relation differs")
    }
    let expected_generic_arity = if delivery.source_name == "print" {
        1
    } else { 0 }
    if generic_arity != expected_generic_arity {
        panic("host import manifest: fixed generic arity differs")
    }
    let (params, result) = match normalized_signature {
        Type::FnType { params, return_type, .. } =>
            (params, return_type),
        _ => panic("host import manifest: fixed source is not callable")
    }
    let list_of_str = Type::StructType {
        name: BUILTIN_LIST, type_params: [STR]
    }
    let signature_matches = if delivery.source_name == "print" {
        params.len() == 1 &&
            match params.get(0).unwrap() {
                Type::TypeVar { id, name } =>
                    id == -1 && name.is_none(),
                _ => false
            } && types_equal(result, UNIT)
    } else if delivery.source_name == "assert" {
        params.len() == 2 &&
            types_equal(params.get(0).unwrap(), BOOL) &&
            types_equal(params.get(1).unwrap(), STR) &&
            types_equal(result, UNIT)
    } else if delivery.source_name == "eprintln" ||
              delivery.source_name == "delete_file" {
        params.len() == 1 &&
            types_equal(params.get(0).unwrap(), STR) &&
            types_equal(result, UNIT)
    } else if delivery.source_name == "read_file" ||
              delivery.source_name == "path_resolve" {
        params.len() == 1 &&
            types_equal(params.get(0).unwrap(), STR) &&
            types_equal(result, STR)
    } else if delivery.source_name == "write_file" {
        params.len() == 2 &&
            types_equal(params.get(0).unwrap(), STR) &&
            types_equal(params.get(1).unwrap(), STR) &&
            types_equal(result, UNIT)
    } else if delivery.source_name == "file_exists" {
        params.len() == 1 &&
            types_equal(params.get(0).unwrap(), STR) &&
            types_equal(result, BOOL)
    } else if delivery.source_name == "argv" {
        params.len() == 0 && types_equal(result, list_of_str)
    } else if delivery.source_name == "exit_process" {
        params.len() == 1 &&
            types_equal(params.get(0).unwrap(), INT) &&
            types_equal(result, UNIT)
    } else if delivery.source_name == "cwd" {
        params.len() == 0 && types_equal(result, STR)
    } else if delivery.source_name == "exec_sync" {
        params.len() == 2 &&
            types_equal(params.get(0).unwrap(), STR) &&
            types_equal(params.get(1).unwrap(), list_of_str) &&
            types_equal(result, INT)
    } else { false }
    if !signature_matches {
        panic("host import manifest: fixed callable header differs")
    }
    let projection = host_import_effect_projection(normalized_signature)
    if projection.failures.len() != 0 {
        panic("host import manifest: fixed failure subset differs")
    }
    match projection.system_effect {
        some(reference) => if !system_effect_ref_same(
                reference, delivery.system_effect) {
            panic("host import manifest: fixed capability differs")
        },
        none => panic("host import manifest: fixed capability is absent")
    }
    for existing in manifest.host_sources {
        if symbol_ref_same(existing.source_symbol, source) ||
           source_sites_same(
                existing.delivery.source_site, delivery.source_site) {
            panic("host import manifest: source registration repeats")
        }
        if executable_ref_same(
                host_import_delivery_executable(existing.delivery),
                host_import_delivery_executable(delivery)) {
            panic("host import manifest: HostOp executable repeats")
        }
    }
    manifest.host_sources.push(HostImportSourceRegistration {
        delivery: delivery, source_symbol: source,
        normalized_signature: normalized_signature,
        generic_arity: generic_arity
    })
}

pub fn register_compiler_extern_source(
    mut manifest: CompilerExternManifest, source: SymbolRef,
    normalized_signature: Type, generic_arity: Int
) -> Bool {
    if manifest.closed {
        panic("compiler extern manifest: registration after closure")
    }
    match host_import_delivery_for_source(source) {
        some(delivery) => register_host_import_source(
            manifest, source, delivery, normalized_signature, generic_arity),
        none => {}
    }
    let delivery = match compiler_extern_delivery_for_source(source) {
        some(value) => value,
        none => return false
    }
    let entry = make_compiler_extern_manifest_entry(
        source, delivery, normalized_signature, generic_arity)
    for existing in manifest.entries {
        if symbol_ref_same(existing.source_symbol, entry.source_symbol) {
            panic("compiler extern manifest: duplicate source identity")
        }
        if compiler_extern_ref_same(existing.intrinsic, entry.intrinsic) {
            if !callable_resource_contract_same(
                    existing.resource, entry.resource) ||
               existing.generic_arity != entry.generic_arity ||
               !types_equal(
                    existing.normalized_signature,
                    entry.normalized_signature) {
                panic("compiler extern manifest: replay contract differs")
            }
            if existing.publish_hdecl && entry.publish_hdecl {
                panic("compiler extern manifest: duplicate publication owner")
            }
        }
    }
    manifest.entries.push(entry)
    true
}

fn close_host_import_sources(manifest: CompilerExternManifest) {
    let deliveries = host_import_source_deliveries()
    if deliveries.len() != HOST_IMPORT_SOURCE_DELIVERY_COUNT ||
       manifest.host_sources.len() != HOST_IMPORT_SOURCE_DELIVERY_COUNT {
        panic("host import manifest: fixed source census is incomplete")
    }
    let mut index = 0
    while index < deliveries.len() {
        let delivery = deliveries.get(index).unwrap()
        let mut right = index + 1
        while right < deliveries.len() {
            let other = deliveries.get(right).unwrap()
            if source_sites_same(
                    delivery.source_site, other.source_site) ||
               executable_ref_same(
                    host_import_delivery_executable(delivery),
                    host_import_delivery_executable(other)) {
                panic("host import manifest: fixed delivery repeats")
            }
            right = right + 1
        }
        let mut matches = 0
        for registered in manifest.host_sources {
            if source_sites_same(
                    registered.delivery.source_site,
                    delivery.source_site) {
                let projection = host_import_effect_projection(
                    registered.normalized_signature)
                let registered_system_matches = match
                        projection.system_effect {
                    some(reference) => system_effect_ref_same(
                        reference, delivery.system_effect),
                    none => false
                }
                let expected_generic_arity =
                    if delivery.source_name == "print" { 1 } else { 0 }
                if !source_symbol_matches_site(
                        registered.source_symbol,
                        delivery.source_site) ||
                   registered.generic_arity !=
                        expected_generic_arity ||
                   !registered_system_matches ||
                   registered.delivery.source_name != delivery.source_name ||
                   registered.delivery.native_target !=
                        delivery.native_target ||
                   !system_effect_ref_same(
                        registered.delivery.system_effect,
                        delivery.system_effect) ||
                   host_import_lowering_tag(
                        registered.delivery.lowering) !=
                        host_import_lowering_tag(delivery.lowering) {
                    panic("host import manifest: fixed delivery payload differs")
                }
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("host import manifest: fixed delivery is not unique")
        }
        index = index + 1
    }
}

pub fn close_compiler_extern_manifest(mut manifest: CompilerExternManifest) {
    if manifest.closed {
        panic("compiler extern manifest: duplicate closure")
    }
    let deliveries = compiler_extern_source_deliveries()
    if deliveries.len() != COMPILER_EXTERN_SOURCE_DELIVERY_COUNT ||
       manifest.entries.len() != COMPILER_EXTERN_SOURCE_DELIVERY_COUNT {
        panic("compiler extern manifest: source census is incomplete")
    }
    let mut delivery_index = 0
    while delivery_index < deliveries.len() {
        let delivery = deliveries.get(delivery_index).unwrap()
        let mut duplicate_index = delivery_index + 1
        while duplicate_index < deliveries.len() {
            let duplicate = deliveries.get(duplicate_index).unwrap()
            if source_sites_same(
                    delivery.source_site, duplicate.source_site) {
                panic("compiler extern manifest: source delivery repeats")
            }
            duplicate_index = duplicate_index + 1
        }
        let mut delivery_count = 0
        for entry in manifest.entries {
            if source_symbol_matches_site(
                    entry.source_symbol, delivery.source_site) &&
               compiler_extern_site_same(
                    compiler_extern_ref_site(entry.intrinsic),
                    delivery.compiler_site) &&
               entry.publish_hdecl == delivery.publish_hdecl {
                delivery_count = delivery_count + 1
            }
        }
        if delivery_count != 1 {
            panic("compiler extern manifest: source delivery is not unique")
        }
        delivery_index = delivery_index + 1
    }
    for tag in 0..COMPILER_EXTERN_SITE_COUNT {
        let expected = compiler_extern_site_from_tag(tag)
        let mut expected_count = 0
        for delivery in deliveries {
            if compiler_extern_site_same(
                    delivery.compiler_site, expected) {
                expected_count = expected_count + 1
            }
        }
        let mut count = 0
        let mut publisher_count = 0
        for entry in manifest.entries {
            if compiler_extern_site_same(
                    compiler_extern_ref_site(entry.intrinsic), expected) {
                count = count + 1
                if entry.publish_hdecl {
                    publisher_count = publisher_count + 1
                }
            }
        }
        if expected_count == 0 || count != expected_count ||
           publisher_count != 1 {
            panic("compiler extern manifest: site relation is not unique")
        }
    }
    close_host_import_sources(manifest)
    manifest.closed = true
}

pub fn compiler_extern_manifest_entry(
    manifest: CompilerExternManifest, source: SymbolRef
) -> CompilerExternManifestEntry? {
    if !manifest.closed {
        if manifest.entries.len() == 0 { return none }
        panic("compiler extern manifest: lookup before closure")
    }
    for entry in manifest.entries {
        if symbol_ref_same(entry.source_symbol, source) ||
           symbol_ref_same(
                compiler_extern_ref_symbol(entry.intrinsic), source) {
            return some(entry)
        }
    }
    none
}

// Exact call identity is needed as soon as one prelude declaration has been
// registered, before the whole census can close. This projection may observe
// only an already-bound entry; it never treats an absent entry as proof that
// the eventual manifest is complete. close_compiler_extern_manifest remains
// the sole census gate.
pub fn registered_compiler_extern_manifest_entry(
    manifest: CompilerExternManifest, source: SymbolRef
) -> CompilerExternManifestEntry? {
    for entry in manifest.entries {
        if symbol_ref_same(entry.source_symbol, source) ||
           symbol_ref_same(
                compiler_extern_ref_symbol(entry.intrinsic), source) {
            return some(entry)
        }
    }
    none
}

// Checker Phase2 asks with the resolver SymbolRef saved on the exact physical
// PreludeDeclSite. A compiler ref is intentionally not accepted here because
// shared sites have two source deliveries but only one publication owner.
pub fn compiler_extern_should_publish_hdecl(
    manifest: CompilerExternManifest, source: SymbolRef
) -> Bool? {
    if !manifest.closed {
        panic("compiler extern manifest: publication query before closure")
    }
    for entry in manifest.entries {
        if symbol_ref_same(entry.source_symbol, source) {
            return some(entry.publish_hdecl)
        }
    }
    none
}

pub fn compiler_extern_manifest_count(
    manifest: CompilerExternManifest
) -> Int { manifest.entries.len() }

pub fn compiler_extern_manifest_published_count(
    manifest: CompilerExternManifest
) -> Int {
    let mut count = 0
    for entry in manifest.entries {
        if entry.publish_hdecl { count = count + 1 }
    }
    count
}

pub fn compiler_extern_manifest_is_closed(
    manifest: CompilerExternManifest
) -> Bool { manifest.closed }
