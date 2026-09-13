use std::collections::{BTreeMap, BTreeSet};

use crate::ast::*;
use crate::project::*;

const LANGUAGE_TYPES: &[&str] = &[
    "Int", "Float", "Str", "Bool", "Unit", "Never", "List", "Range", "Ptr",
];
const CORE_ENUMS: &[&str] = &["Option", "Ordering"];
const CORE_TRAITS: &[&str] = &[
    "PartialEq",
    "Eq",
    "PartialOrd",
    "Ord",
    "Clone",
    "Copy",
    "Drop",
    "Display",
    "Debug",
    "Hash",
    "FnOnce",
    "FnMut",
    "Fn",
    "Iterator",
    "Iterable",
];
const LANGUAGE_EFFECTS: &[&str] = &["console", "fs", "process", "fail", "mut", "unsafe"];

#[derive(Clone, Copy)]
enum ExpectedCoreVariant {
    Unit,
    Positional(usize),
}

pub(crate) fn resolve_project(
    sources: &ProjectSources,
) -> Result<ResolvedProject, ProjectDiagnostic> {
    let reachable_libraries = validate_library_graph(sources)?;
    let parsed = parse_reachable_sources(sources, &reachable_libraries)?;
    let modules = build_module_graph(sources, &reachable_libraries, &parsed)?;
    if let Some(diagnostic) = first_generate_diagnostic(&modules) {
        return Err(diagnostic);
    }
    let dependencies = reachable_libraries
        .iter()
        .map(|library| {
            (
                *library,
                sources
                    .libraries
                    .get(library)
                    .expect("reachable libraries were validated")
                    .dependencies
                    .clone(),
            )
        })
        .collect();
    let mut state = ResolverState::new(modules, sources.entry, sources.core, dependencies);
    state.index_entities()?;
    state.resolve_imports()?;
    state.resolve_bodies()
}

fn validate_library_graph(
    sources: &ProjectSources,
) -> Result<BTreeSet<LibraryId>, ProjectDiagnostic> {
    if !sources.libraries.contains_key(&sources.entry) {
        return Err(input_diagnostic(
            ProjectDiagnosticKind::MissingEntryLibrary {
                entry: sources.entry,
            },
        ));
    }

    if !sources.libraries.contains_key(&sources.core) {
        return Err(input_diagnostic(
            ProjectDiagnosticKind::MissingCoreLibrary { core: sources.core },
        ));
    }

    for (owner, library) in &sources.libraries {
        for alias in library.dependencies.keys() {
            if !is_valid_dependency_alias(alias) {
                return Err(input_diagnostic(
                    ProjectDiagnosticKind::InvalidDependencyAlias {
                        owner: *owner,
                        alias: alias.clone(),
                    },
                ));
            }
        }
    }

    for (owner, library) in &sources.libraries {
        for (alias, target) in &library.dependencies {
            if !sources.libraries.contains_key(target) {
                return Err(input_diagnostic(
                    ProjectDiagnosticKind::MissingDependencyTarget {
                        owner: *owner,
                        alias: alias.clone(),
                        target: *target,
                    },
                ));
            }
        }
    }

    if let Some(cycle) = first_library_dependency_cycle(&sources.libraries) {
        return Err(input_diagnostic(
            ProjectDiagnosticKind::LibraryDependencyCycle { cycle },
        ));
    }

    let mut reachable = BTreeSet::new();
    let mut pending = BTreeSet::from([sources.entry]);
    while let Some(library) = pending.pop_first() {
        if !reachable.insert(library) {
            continue;
        }
        pending.extend(
            sources
                .libraries
                .get(&library)
                .expect("dependency targets were validated")
                .dependencies
                .values()
                .copied(),
        );
    }
    if let Some(owner) = reachable.iter().copied().find(|owner| {
        *owner != sources.core
            && !sources.libraries[owner]
                .dependencies
                .values()
                .any(|target| *target == sources.core)
    }) {
        return Err(input_diagnostic(
            ProjectDiagnosticKind::MissingDirectCoreDependency {
                owner,
                core: sources.core,
            },
        ));
    }
    Ok(reachable)
}

fn input_diagnostic(kind: ProjectDiagnosticKind) -> ProjectDiagnostic {
    ProjectDiagnostic {
        kind,
        primary: None,
        related: Vec::new(),
    }
}

fn core_role_diagnostic(
    core: LibraryId,
    role: &str,
    member: Option<&str>,
    issue: CoreRoleIssue,
    target: &EntityId,
) -> ProjectDiagnostic {
    ProjectDiagnostic {
        kind: ProjectDiagnosticKind::InvalidCoreRole(Box::new(CoreRoleDiagnostic {
            core,
            role: role.to_owned(),
            member: member.map(str::to_owned),
            issue,
        })),
        primary: entity_origin(target),
        related: Vec::new(),
    }
}

fn first_library_dependency_cycle(
    libraries: &BTreeMap<LibraryId, LibrarySources>,
) -> Option<Vec<LibraryId>> {
    let mut complete = BTreeSet::new();
    for library in libraries.keys().copied() {
        if let Some(cycle) = visit_library_dependency(library, libraries, &mut complete) {
            return Some(canonicalize_library_cycle(cycle));
        }
    }
    None
}

fn visit_library_dependency(
    library: LibraryId,
    libraries: &BTreeMap<LibraryId, LibrarySources>,
    complete: &mut BTreeSet<LibraryId>,
) -> Option<Vec<LibraryId>> {
    if complete.contains(&library) {
        return None;
    }

    let mut active = BTreeMap::from([(library, 0)]);
    let mut stack = vec![(
        library,
        libraries
            .get(&library)
            .expect("dependency targets were validated")
            .dependencies
            .values(),
    )];
    while let Some((_, dependencies)) = stack.last_mut() {
        if let Some(dependency) = dependencies.next().copied() {
            if complete.contains(&dependency) {
                continue;
            }
            if let Some(start) = active.get(&dependency).copied() {
                let mut cycle = stack[start..]
                    .iter()
                    .map(|(library, _)| *library)
                    .collect::<Vec<_>>();
                cycle.push(dependency);
                return Some(cycle);
            }

            active.insert(dependency, stack.len());
            stack.push((
                dependency,
                libraries
                    .get(&dependency)
                    .expect("dependency targets were validated")
                    .dependencies
                    .values(),
            ));
        } else {
            let (completed, _) = stack.pop().expect("the visit stack is nonempty");
            active.remove(&completed);
            complete.insert(completed);
        }
    }
    None
}

fn canonicalize_library_cycle(cycle: Vec<LibraryId>) -> Vec<LibraryId> {
    debug_assert!(cycle.len() >= 2 && cycle.first() == cycle.last());
    let nodes = &cycle[..cycle.len() - 1];
    let start = nodes
        .iter()
        .enumerate()
        .min_by_key(|(_, library)| **library)
        .map(|(index, _)| index)
        .expect("a cycle contains at least one node");
    let mut canonical = nodes[start..]
        .iter()
        .chain(nodes[..start].iter())
        .copied()
        .collect::<Vec<_>>();
    canonical.push(canonical[0]);
    canonical
}

#[derive(Clone)]
struct ParsedSource {
    origin: SourceRef,
    program: Program,
}

fn parse_reachable_sources(
    sources: &ProjectSources,
    reachable_libraries: &BTreeSet<LibraryId>,
) -> Result<BTreeMap<ModuleRef, ParsedSource>, ProjectDiagnostic> {
    let inventory = inventory_modules(sources, reachable_libraries);
    let file_sources = sources
        .libraries
        .iter()
        .filter(|(library, _)| reachable_libraries.contains(library))
        .flat_map(|(library, sources)| {
            sources
                .modules
                .iter()
                .map(|(path, source)| (ModuleRef::from_file(*library, path), (path, source)))
        })
        .collect::<BTreeMap<_, _>>();
    let mut attempted = BTreeSet::new();
    let mut parsed = BTreeMap::new();
    let mut failures = BTreeMap::<ModuleRef, ProjectDiagnostic>::new();
    let mut pending = reachable_libraries
        .iter()
        .copied()
        .map(ModuleRef::root)
        .collect::<BTreeSet<_>>();

    loop {
        while let Some(module) = pending.pop_first() {
            if !attempted.insert(module.clone()) {
                continue;
            }
            let library = module.library();
            let (origin, source) = if module.is_root() {
                (
                    SourceRef::Root,
                    sources
                        .libraries
                        .get(&library)
                        .expect("reachable library exists")
                        .root
                        .as_str(),
                )
            } else {
                let Some((path, source)) = file_sources.get(&module) else {
                    continue;
                };
                (SourceRef::File((*path).clone()), source.as_str())
            };
            match crate::parse(source) {
                Ok(program) => {
                    parsed.insert(module, ParsedSource { origin, program });
                }
                Err(diagnostic) => {
                    failures.insert(
                        module,
                        ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::Frontend(diagnostic.kind),
                            primary: Some(OriginRef {
                                library,
                                source: origin,
                                span: diagnostic.span,
                            }),
                            related: Vec::new(),
                        },
                    );
                }
            }
        }

        let (known_modules, uses) = discovery_snapshot(&inventory, &parsed);
        let (aliases, visited) = discover_module_aliases(&known_modules, &uses);
        let mut newly_reachable = visited;
        for (module, use_declaration) in &uses {
            newly_reachable.extend(modules_named_by_use(
                module,
                use_declaration,
                &known_modules,
                &aliases,
            ));
        }
        newly_reachable.retain(|module| file_sources.contains_key(module));
        newly_reachable.retain(|module| !attempted.contains(module));
        if newly_reachable.is_empty() {
            break;
        }
        pending = newly_reachable;
    }

    if let Some((_, diagnostic)) = failures.pop_first() {
        return Err(diagnostic);
    }
    Ok(parsed)
}

fn inventory_modules(
    sources: &ProjectSources,
    reachable_libraries: &BTreeSet<LibraryId>,
) -> BTreeSet<ModuleRef> {
    let mut modules = BTreeSet::new();
    for library in reachable_libraries {
        modules.insert(ModuleRef::root(*library));
        for path in sources
            .libraries
            .get(library)
            .expect("reachable library exists")
            .modules
            .keys()
        {
            for length in 1..=path.segments().len() {
                modules.insert(ModuleRef::Source {
                    library: *library,
                    path: path.segments()[..length].to_vec(),
                });
            }
        }
    }
    modules
}

fn discovery_snapshot(
    inventory: &BTreeSet<ModuleRef>,
    parsed: &BTreeMap<ModuleRef, ParsedSource>,
) -> (BTreeSet<ModuleRef>, Vec<(ModuleRef, UseDeclaration)>) {
    let mut modules = inventory.clone();
    let mut uses = Vec::new();
    for (module, source) in parsed {
        collect_discovery_items(
            module,
            &source.program.uses,
            &source.program.items,
            &mut modules,
            &mut uses,
        );
    }
    (modules, uses)
}

fn collect_discovery_items(
    module: &ModuleRef,
    module_uses: &[UseDeclaration],
    items: &[ModuleItem],
    modules: &mut BTreeSet<ModuleRef>,
    uses: &mut Vec<(ModuleRef, UseDeclaration)>,
) {
    uses.extend(
        module_uses
            .iter()
            .cloned()
            .map(|use_declaration| (module.clone(), use_declaration)),
    );
    for item in items {
        let ModuleItem::Declaration(declaration) = item else {
            continue;
        };
        if let DeclarationKind::Module(declared) = &declaration.kind {
            let child = module.child(&declared.item.name.text);
            modules.insert(child.clone());
            collect_discovery_items(
                &child,
                &declared.item.uses,
                &declared.item.items,
                modules,
                uses,
            );
        }
    }
}

type ModuleAliases = BTreeMap<(ModuleRef, String), BTreeSet<ModuleRef>>;

fn discover_module_aliases(
    modules: &BTreeSet<ModuleRef>,
    uses: &[(ModuleRef, UseDeclaration)],
) -> (ModuleAliases, BTreeSet<ModuleRef>) {
    let mut aliases = ModuleAliases::new();
    let mut all_visited = BTreeSet::new();
    loop {
        let mut changed = false;
        for (module, declaration) in uses {
            let (base_targets, visited) =
                scan_module_path(module, &declaration.path, modules, &aliases);
            all_visited.extend(visited);
            match &declaration.suffix {
                Some(UseSuffix::Items { items, .. }) => {
                    for item in items {
                        let mut targets = BTreeSet::new();
                        for base in &base_targets {
                            targets.extend(module_children_named(
                                base,
                                &item.name.text,
                                modules,
                                &aliases,
                            ));
                        }
                        all_visited.extend(targets.iter().cloned());
                        let local_name = item.alias.as_ref().unwrap_or(&item.name).text.clone();
                        let entry = aliases.entry((module.clone(), local_name)).or_default();
                        let old_length = entry.len();
                        entry.extend(targets);
                        changed |= entry.len() != old_length;
                    }
                }
                suffix => {
                    let local_name = match suffix {
                        Some(UseSuffix::Alias(alias)) => Some(alias.text.clone()),
                        None => path_terminal_name(&declaration.path),
                        Some(UseSuffix::Items { .. }) => unreachable!(),
                    };
                    if let Some(local_name) = local_name {
                        let entry = aliases.entry((module.clone(), local_name)).or_default();
                        let old_length = entry.len();
                        entry.extend(base_targets);
                        changed |= entry.len() != old_length;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    (aliases, all_visited)
}

fn modules_named_by_use(
    module: &ModuleRef,
    declaration: &UseDeclaration,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> BTreeSet<ModuleRef> {
    let (targets, mut visited) = scan_module_path(module, &declaration.path, modules, aliases);
    if let Some(UseSuffix::Items { items, .. }) = &declaration.suffix {
        for target in targets {
            for item in items {
                let children = module_children_named(&target, &item.name.text, modules, aliases);
                visited.extend(children);
            }
        }
    }
    visited
}

fn scan_module_path(
    current: &ModuleRef,
    path: &Path,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> (BTreeSet<ModuleRef>, BTreeSet<ModuleRef>) {
    let mut visited = BTreeSet::new();
    let Some((mut candidates, start_index)) = module_path_start(current, path, modules, aliases)
    else {
        return (BTreeSet::new(), visited);
    };
    visited.extend(candidates.iter().cloned());
    for segment in &path.segments[start_index..] {
        let PathSegment::Identifier(identifier) = segment else {
            return (BTreeSet::new(), visited);
        };
        let mut next = BTreeSet::new();
        for candidate in &candidates {
            next.extend(module_children_named(
                candidate,
                &identifier.text,
                modules,
                aliases,
            ));
        }
        if next.is_empty() {
            return (BTreeSet::new(), visited);
        }
        visited.extend(next.iter().cloned());
        candidates = next;
    }
    (candidates, visited)
}

fn module_path_start(
    current: &ModuleRef,
    path: &Path,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> Option<(BTreeSet<ModuleRef>, usize)> {
    let first = path.segments.first()?;
    match first {
        PathSegment::Super(_) => {
            let mut base = current.clone();
            let mut index = 0;
            while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                base = base.parent()?;
                index += 1;
            }
            Some((BTreeSet::from([base]), index))
        }
        PathSegment::Identifier(identifier)
            if path.segments.len() > 1 && identifier.text == "root" =>
        {
            Some((BTreeSet::from([ModuleRef::root(current.library())]), 1))
        }
        PathSegment::Identifier(identifier)
            if path.segments.len() > 1 && identifier.text == "self" =>
        {
            Some((BTreeSet::from([current.clone()]), 1))
        }
        PathSegment::Identifier(identifier) => {
            let candidates = module_children_named(current, &identifier.text, modules, aliases);
            (!candidates.is_empty()).then_some((candidates, 1))
        }
    }
}

fn module_children_named(
    module: &ModuleRef,
    name: &str,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> BTreeSet<ModuleRef> {
    let mut children = aliases
        .get(&(module.clone(), name.to_owned()))
        .cloned()
        .unwrap_or_default();
    let direct = module.child(name);
    if modules.contains(&direct) {
        children.insert(direct);
    }
    children
}

fn path_terminal_name(path: &Path) -> Option<String> {
    match path.segments.last()? {
        PathSegment::Identifier(identifier) => Some(identifier.text.clone()),
        PathSegment::Super(_) => None,
    }
}

#[derive(Clone)]
struct ModuleBodyAst {
    origin: SourceRef,
    span: Span,
    requires: Option<EffectSet>,
    uses: Vec<UseDeclaration>,
    declarations: Vec<Declaration>,
    generates: Vec<GenerateItem>,
}

struct ModuleInfo {
    body: Option<ModuleBodyAst>,
    file_body_present: bool,
    declared_at: Option<OriginRef>,
    public: bool,
}

fn split_module_items(items: &[ModuleItem]) -> (Vec<Declaration>, Vec<GenerateItem>) {
    let mut declarations = Vec::new();
    let mut generates = Vec::new();
    for item in items {
        match item {
            ModuleItem::Declaration(declaration) => declarations.push(declaration.as_ref().clone()),
            ModuleItem::Generate(generate) => generates.push(generate.clone()),
        }
    }
    (declarations, generates)
}

fn build_module_graph(
    sources: &ProjectSources,
    reachable_libraries: &BTreeSet<LibraryId>,
    parsed: &BTreeMap<ModuleRef, ParsedSource>,
) -> Result<BTreeMap<ModuleRef, ModuleInfo>, ProjectDiagnostic> {
    let mut modules = BTreeMap::new();
    for library in reachable_libraries {
        modules.insert(
            ModuleRef::root(*library),
            ModuleInfo {
                body: None,
                file_body_present: false,
                declared_at: None,
                public: true,
            },
        );
        for path in sources
            .libraries
            .get(library)
            .expect("reachable library exists")
            .modules
            .keys()
        {
            for length in 1..=path.segments().len() {
                let module = ModuleRef::Source {
                    library: *library,
                    path: path.segments()[..length].to_vec(),
                };
                let exact = length == path.segments().len();
                modules
                    .entry(module)
                    .and_modify(|info| info.file_body_present |= exact)
                    .or_insert(ModuleInfo {
                        body: None,
                        file_body_present: exact,
                        declared_at: None,
                        public: true,
                    });
            }
        }
    }

    for (module, parsed_source) in parsed {
        let (declarations, generates) = split_module_items(&parsed_source.program.items);
        let body = ModuleBodyAst {
            origin: parsed_source.origin.clone(),
            span: parsed_source.program.span,
            requires: parsed_source
                .program
                .requires
                .as_ref()
                .map(|requires| requires.effects.clone()),
            uses: parsed_source.program.uses.clone(),
            declarations,
            generates,
        };
        modules
            .entry(module.clone())
            .or_insert(ModuleInfo {
                body: None,
                file_body_present: !module.is_root(),
                declared_at: None,
                public: true,
            })
            .body = Some(body);
    }

    let mut diagnostics = Vec::new();
    for (module, parsed_source) in parsed {
        diagnostics.extend(register_inline_modules(
            module,
            &parsed_source.origin,
            &parsed_source.program.items,
            &mut modules,
        ));
    }
    if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
        return Err(diagnostic);
    }
    Ok(modules)
}

fn register_inline_modules(
    parent: &ModuleRef,
    source: &SourceRef,
    items: &[ModuleItem],
    modules: &mut BTreeMap<ModuleRef, ModuleInfo>,
) -> Vec<(ModuleRef, ProjectDiagnostic)> {
    let mut diagnostics = Vec::new();
    for item in items {
        let ModuleItem::Declaration(declaration) = item else {
            continue;
        };
        let DeclarationKind::Module(declared) = &declaration.kind else {
            continue;
        };
        let name = &declared.item.name;
        let module = parent.child(&name.text);
        if is_reserved_module_segment(&name.text) {
            diagnostics.push((
                module,
                ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::InvalidModuleName {
                        name: name.text.clone(),
                    },
                    primary: Some(OriginRef {
                        library: parent.library(),
                        source: source.clone(),
                        span: name.span,
                    }),
                    related: Vec::new(),
                },
            ));
            continue;
        }
        let origin = OriginRef {
            library: parent.library(),
            source: source.clone(),
            span: name.span,
        };
        let entry = modules.entry(module.clone()).or_insert(ModuleInfo {
            body: None,
            file_body_present: false,
            declared_at: None,
            public: declared.visibility.is_some(),
        });
        if entry.file_body_present || entry.body.is_some() {
            let related = entry.declared_at.clone().into_iter().collect();
            diagnostics.push((
                module.clone(),
                ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::ModuleBodyConflict {
                        module: module.path().to_vec(),
                    },
                    primary: Some(origin),
                    related,
                },
            ));
            continue;
        }
        entry.declared_at = Some(origin);
        entry.public = declared.visibility.is_some();
        let (declarations, generates) = split_module_items(&declared.item.items);
        entry.body = Some(ModuleBodyAst {
            origin: source.clone(),
            span: declaration.span,
            requires: declared.item.requires.clone(),
            uses: declared.item.uses.clone(),
            declarations,
            generates,
        });
        diagnostics.extend(register_inline_modules(
            &module,
            source,
            &declared.item.items,
            modules,
        ));
    }
    diagnostics
}

fn first_generate_diagnostic(
    modules: &BTreeMap<ModuleRef, ModuleInfo>,
) -> Option<ProjectDiagnostic> {
    let diagnostics = modules
        .iter()
        .flat_map(|(module, info)| {
            info.body.iter().flat_map(move |body| {
                body.generates.iter().map(move |generate| {
                    (
                        module.clone(),
                        ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::GenerateUnsupported,
                            primary: Some(OriginRef {
                                library: module.library(),
                                source: body.origin.clone(),
                                span: generate.keyword_span,
                            }),
                            related: Vec::new(),
                        },
                    )
                })
            })
        })
        .collect();
    first_stage_diagnostic(diagnostics)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Delivery {
    target: EntityId,
    public: bool,
    owner_module: ModuleRef,
    origin: Option<OriginRef>,
}

type BindingTable = BTreeMap<(Namespace, String), BTreeMap<EntityId, Delivery>>;

#[derive(Clone)]
struct ImportDirective {
    module: ModuleRef,
    origin: OriginRef,
    public: bool,
    path: Path,
    local_name: String,
    candidates: BTreeSet<EntityId>,
    inaccessible: BTreeSet<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
}

struct ResolverState {
    modules: BTreeMap<ModuleRef, ModuleInfo>,
    entry: LibraryId,
    core: LibraryId,
    dependencies: BTreeMap<LibraryId, BTreeMap<String, LibraryId>>,
    entities: BTreeMap<EntityId, Entity>,
    core_bindings: BTreeMap<String, EntityId>,
    core_roles: Option<CoreRoles>,
    closed_member_owners: BTreeSet<EntityId>,
    own_bindings: BTreeMap<ModuleRef, BindingTable>,
    bindings: BTreeMap<ModuleRef, BindingTable>,
    imports: Vec<ImportDirective>,
}

impl ResolverState {
    fn new(
        modules: BTreeMap<ModuleRef, ModuleInfo>,
        entry: LibraryId,
        core: LibraryId,
        dependencies: BTreeMap<LibraryId, BTreeMap<String, LibraryId>>,
    ) -> Self {
        Self {
            modules,
            entry,
            core,
            dependencies,
            entities: BTreeMap::new(),
            core_bindings: BTreeMap::new(),
            core_roles: None,
            closed_member_owners: BTreeSet::new(),
            own_bindings: BTreeMap::new(),
            bindings: BTreeMap::new(),
            imports: Vec::new(),
        }
    }

    fn index_entities(&mut self) -> Result<(), ProjectDiagnostic> {
        self.index_intrinsic_entities();
        self.index_modules();
        let mut diagnostics = Vec::new();
        let bodies = self
            .modules
            .iter()
            .filter_map(|(module, info)| info.body.clone().map(|body| (module.clone(), body)))
            .collect::<Vec<_>>();
        for (module, body) in bodies {
            diagnostics.extend(
                self.index_declarations(&module, &body)
                    .into_iter()
                    .map(|diagnostic| (module.clone(), diagnostic)),
            );
            self.imports
                .extend(flatten_imports(&module, &body.origin, &body.uses));
        }
        for (module, table) in &self.own_bindings {
            if let Some(diagnostic) = first_binding_diagnostic(self.core, module, table) {
                diagnostics.push((module.clone(), diagnostic));
            }
        }
        if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
            return Err(diagnostic);
        }
        let core_roles = self.index_core_roles()?;
        self.core_bindings = core_role_bindings(&core_roles);
        self.core_roles = Some(core_roles);
        self.bindings = self.own_bindings.clone();
        Ok(())
    }

    fn index_intrinsic_entities(&mut self) {
        for name in LANGUAGE_TYPES {
            self.insert_language_entity(Namespace::Type, EntityKind::LanguageType, name, None);
        }
        for name in LANGUAGE_EFFECTS {
            self.insert_language_entity(Namespace::Effect, EntityKind::LanguageEffect, name, None);
        }
        let fail = language_id(Namespace::Effect, EntityKind::LanguageEffect, "fail", None);
        self.insert_language_member(
            &fail,
            Namespace::Value,
            EntityKind::EffectOperation,
            "raise",
        );
    }

    fn index_core_roles(&self) -> Result<CoreRoles, ProjectDiagnostic> {
        let (option_declaration, option_id) =
            self.require_core_declaration("Option", EntityKind::Enum, 1)?;
        let option_variants = self.require_core_enum_variants(
            "Option",
            option_declaration,
            &option_id,
            &[
                ("Some", ExpectedCoreVariant::Positional(1)),
                ("None", ExpectedCoreVariant::Unit),
            ],
        )?;
        let option = CoreOptionRole {
            declaration: option_id,
            some: option_variants[0].clone(),
            none: option_variants[1].clone(),
        };

        let (ordering_declaration, ordering_id) =
            self.require_core_declaration("Ordering", EntityKind::Enum, 0)?;
        let ordering_variants = self.require_core_enum_variants(
            "Ordering",
            ordering_declaration,
            &ordering_id,
            &[
                ("Less", ExpectedCoreVariant::Unit),
                ("Equal", ExpectedCoreVariant::Unit),
                ("Greater", ExpectedCoreVariant::Unit),
            ],
        )?;
        let ordering = CoreOrderingRole {
            declaration: ordering_id,
            less: ordering_variants[0].clone(),
            equal: ordering_variants[1].clone(),
            greater: ordering_variants[2].clone(),
        };

        Ok(CoreRoles {
            option,
            ordering,
            partial_eq: self.require_core_method_trait("PartialEq", "eq")?,
            eq: self.require_core_empty_trait("Eq")?,
            partial_ord: self.require_core_method_trait("PartialOrd", "partial_cmp")?,
            ord: self.require_core_method_trait("Ord", "cmp")?,
            clone: self.require_core_method_trait("Clone", "clone")?,
            copy: self.require_core_empty_trait("Copy")?,
            drop: self.require_core_method_trait("Drop", "drop")?,
            display: self.require_core_method_trait("Display", "to_str")?,
            debug: self.require_core_method_trait("Debug", "debug")?,
            hash: self.require_core_method_trait("Hash", "hash")?,
            fn_once: self.require_core_empty_trait("FnOnce")?,
            fn_mut: self.require_core_empty_trait("FnMut")?,
            function: self.require_core_empty_trait("Fn")?,
            iterator: self.require_core_iterator()?,
            iterable: self.require_core_iterable()?,
        })
    }

    fn require_core_declaration<'a>(
        &'a self,
        role: &str,
        expected_kind: EntityKind,
        expected_arity: usize,
    ) -> Result<(&'a Declaration, EntityId), ProjectDiagnostic> {
        let root = ModuleRef::root(self.core);
        let body = self
            .modules
            .get(&root)
            .and_then(|module| module.body.as_ref())
            .expect("the reachable core root was parsed before declaration indexing");
        let candidate = body.declarations.iter().find_map(|declaration| {
            let (identity, _) = declaration_entity(&root, &body.origin, declaration)?;
            (identity.namespace == Namespace::Type && identity.name == role)
                .then_some((declaration, identity))
        });
        let Some((declaration, identity)) = candidate else {
            return Err(input_diagnostic(ProjectDiagnosticKind::MissingCoreRole {
                core: self.core,
                role: role.to_owned(),
            }));
        };
        if identity.kind != expected_kind {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::DeclarationKind,
                &identity,
            ));
        }
        if !self
            .entities
            .get(&identity)
            .is_some_and(|entity| entity.public)
        {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::Visibility,
                &identity,
            ));
        }
        let parameters = match &declaration.kind {
            DeclarationKind::Enum(declared) => &declared.item.type_parameters,
            DeclarationKind::Trait(declared) => &declared.item.type_parameters,
            _ => unreachable!("the expected core declaration kind was checked"),
        };
        if parameters.len() != expected_arity {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::GenericArity {
                    expected: expected_arity,
                    actual: parameters.len(),
                },
                &identity,
            ));
        }
        if parameters
            .iter()
            .any(|parameter| !parameter.bounds.is_empty())
        {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::GenericBounds,
                &identity,
            ));
        }
        Ok((declaration, identity))
    }

    fn require_core_enum_variants(
        &self,
        role: &str,
        declaration: &Declaration,
        identity: &EntityId,
        expected: &[(&str, ExpectedCoreVariant)],
    ) -> Result<Vec<EntityId>, ProjectDiagnostic> {
        let DeclarationKind::Enum(declared) = &declaration.kind else {
            unreachable!("the core enum declaration kind was checked")
        };
        if declared.item.variants.len() != expected.len()
            || declared
                .item
                .variants
                .iter()
                .zip(expected)
                .any(|(variant, (name, _))| variant.name.text != *name)
        {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::VariantSet,
                identity,
            ));
        }
        let mut variants = Vec::new();
        for (variant, (name, shape)) in declared.item.variants.iter().zip(expected) {
            let valid_shape = match (&variant.fields, shape) {
                (VariantFields::Unit, ExpectedCoreVariant::Unit) => true,
                (VariantFields::Positional(fields), ExpectedCoreVariant::Positional(count)) => {
                    fields.len() == *count
                }
                _ => false,
            };
            let member =
                self.require_core_member(role, identity, name, EntityKind::EnumConstructor)?;
            if !valid_shape {
                return Err(core_role_diagnostic(
                    self.core,
                    role,
                    Some(name),
                    CoreRoleIssue::VariantPayload,
                    &member,
                ));
            }
            variants.push(member);
        }
        Ok(variants)
    }

    fn require_core_method_trait(
        &self,
        role: &str,
        method: &str,
    ) -> Result<CoreMethodRole, ProjectDiagnostic> {
        let (declaration, identity) = self.require_core_declaration(role, EntityKind::Trait, 0)?;
        let members = self.require_core_trait_members(
            role,
            declaration,
            &identity,
            &[(method, EntityKind::Method)],
        )?;
        Ok(CoreMethodRole {
            declaration: identity,
            method: members[0].clone(),
        })
    }

    fn require_core_empty_trait(&self, role: &str) -> Result<EntityId, ProjectDiagnostic> {
        let (declaration, identity) = self.require_core_declaration(role, EntityKind::Trait, 0)?;
        self.require_core_trait_members(role, declaration, &identity, &[])?;
        Ok(identity)
    }

    fn require_core_iterator(&self) -> Result<CoreIteratorRole, ProjectDiagnostic> {
        let role = "Iterator";
        let (declaration, identity) = self.require_core_declaration(role, EntityKind::Trait, 0)?;
        let members = self.require_core_trait_members(
            role,
            declaration,
            &identity,
            &[
                ("Item", EntityKind::AssociatedType),
                ("next", EntityKind::Method),
            ],
        )?;
        Ok(CoreIteratorRole {
            declaration: identity,
            item: members[0].clone(),
            next: members[1].clone(),
        })
    }

    fn require_core_iterable(&self) -> Result<CoreIterableRole, ProjectDiagnostic> {
        let role = "Iterable";
        let (declaration, identity) = self.require_core_declaration(role, EntityKind::Trait, 0)?;
        let members = self.require_core_trait_members(
            role,
            declaration,
            &identity,
            &[
                ("Item", EntityKind::AssociatedType),
                ("Iter", EntityKind::AssociatedType),
                ("iter", EntityKind::Method),
            ],
        )?;
        Ok(CoreIterableRole {
            declaration: identity,
            item: members[0].clone(),
            iter_type: members[1].clone(),
            iter: members[2].clone(),
        })
    }

    fn require_core_trait_members(
        &self,
        role: &str,
        declaration: &Declaration,
        identity: &EntityId,
        expected: &[(&str, EntityKind)],
    ) -> Result<Vec<EntityId>, ProjectDiagnostic> {
        let DeclarationKind::Trait(declared) = &declaration.kind else {
            unreachable!("the core trait declaration kind was checked")
        };
        let mut actual_names = declared
            .item
            .members
            .iter()
            .map(|member| match &member.kind {
                TraitMemberKind::Method(method) => method.name.text.as_str(),
                TraitMemberKind::AssociatedType(associated) => associated.name.text.as_str(),
            })
            .collect::<Vec<_>>();
        let mut expected_names = expected.iter().map(|(name, _)| *name).collect::<Vec<_>>();
        actual_names.sort_unstable();
        expected_names.sort_unstable();
        if actual_names != expected_names {
            return Err(core_role_diagnostic(
                self.core,
                role,
                None,
                CoreRoleIssue::MemberSet,
                identity,
            ));
        }
        let mut members = Vec::new();
        for (name, kind) in expected {
            let actual_kind = declared.item.members.iter().find_map(|member| {
                let (member_name, member_kind) = match &member.kind {
                    TraitMemberKind::Method(method) => {
                        (method.name.text.as_str(), EntityKind::Method)
                    }
                    TraitMemberKind::AssociatedType(associated) => {
                        (associated.name.text.as_str(), EntityKind::AssociatedType)
                    }
                };
                (member_name == *name).then_some(member_kind)
            });
            if actual_kind != Some(*kind) {
                return Err(core_role_diagnostic(
                    self.core,
                    role,
                    Some(name),
                    CoreRoleIssue::MemberKind,
                    identity,
                ));
            }
            members.push(self.require_core_member(role, identity, name, *kind)?);
        }
        Ok(members)
    }

    fn require_core_member(
        &self,
        role: &str,
        owner: &EntityId,
        name: &str,
        kind: EntityKind,
    ) -> Result<EntityId, ProjectDiagnostic> {
        self.entities
            .get(owner)
            .and_then(|entity| entity.members.get(name))
            .into_iter()
            .flatten()
            .find(|member| member.kind == kind)
            .cloned()
            .ok_or_else(|| {
                core_role_diagnostic(self.core, role, Some(name), CoreRoleIssue::MemberSet, owner)
            })
    }

    fn insert_language_entity(
        &mut self,
        namespace: Namespace,
        kind: EntityKind,
        name: &str,
        owner: Option<OwnerKey>,
    ) {
        let id = language_id(namespace, kind, name, owner);
        self.entities.insert(
            id,
            Entity {
                declared_at: None,
                public: true,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn insert_language_member(
        &mut self,
        owner: &EntityId,
        namespace: Namespace,
        kind: EntityKind,
        name: &str,
    ) {
        let id = language_id(namespace, kind, name, Some(owner_key_from_entity(owner)));
        self.entities.insert(
            id.clone(),
            Entity {
                declared_at: None,
                public: true,
                owner: Some(owner.clone()),
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
        self.entities
            .get_mut(owner)
            .expect("language member owner exists")
            .members
            .entry(name.to_owned())
            .or_default()
            .push(id);
    }

    fn index_modules(&mut self) {
        for (module, info) in &self.modules {
            self.own_bindings.entry(module.clone()).or_default();
            let id = module_id(module);
            self.entities.insert(
                id.clone(),
                Entity {
                    declared_at: info.declared_at.clone(),
                    public: info.public,
                    owner: None,
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
            if module.is_root() {
                continue;
            }
            let parent = module.parent().expect("non-root module has a parent");
            let name = module
                .path()
                .last()
                .expect("non-root module has a name")
                .clone();
            add_delivery(
                self.own_bindings.entry(parent.clone()).or_default(),
                Delivery {
                    target: id,
                    public: info.public,
                    owner_module: parent,
                    origin: info.declared_at.clone(),
                },
                Namespace::Type,
                name,
            );
        }

        for (owner, dependencies) in &self.dependencies {
            let root = ModuleRef::root(*owner);
            let table = self
                .own_bindings
                .get_mut(&root)
                .expect("every reachable library has a root module");
            for (alias, target) in dependencies {
                add_delivery(
                    table,
                    Delivery {
                        target: module_id(&ModuleRef::root(*target)),
                        public: false,
                        owner_module: root.clone(),
                        origin: None,
                    },
                    Namespace::Type,
                    alias.clone(),
                );
            }
        }
    }

    fn index_declarations(
        &mut self,
        module: &ModuleRef,
        body: &ModuleBodyAst,
    ) -> Vec<ProjectDiagnostic> {
        let mut diagnostics = Vec::new();
        for declaration in &body.declarations {
            let Some((id, public)) = declaration_entity(module, &body.origin, declaration) else {
                diagnostics.extend(self.index_impl_members(module, &body.origin, declaration));
                continue;
            };
            if id.kind == EntityKind::Module {
                continue;
            }
            let declared_at = match &id.site {
                EntitySite::Source(origin) => Some(origin.clone()),
                EntitySite::Language | EntitySite::Module(_) => None,
            };
            self.entities.insert(
                id.clone(),
                Entity {
                    declared_at: declared_at.clone(),
                    public,
                    owner: None,
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
            if matches!(
                &declaration.kind,
                DeclarationKind::Trait(declared) if declared.item.supertraits.is_empty()
            ) {
                self.closed_member_owners.insert(id.clone());
            }
            add_delivery(
                self.own_bindings.entry(module.clone()).or_default(),
                Delivery {
                    target: id.clone(),
                    public,
                    owner_module: module.clone(),
                    origin: declared_at,
                },
                id.namespace,
                id.name.clone(),
            );
            diagnostics.extend(self.index_owned_members(module, &body.origin, declaration, &id));
        }
        diagnostics
    }

    fn index_owned_members(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        declaration: &Declaration,
        owner: &EntityId,
    ) -> Vec<ProjectDiagnostic> {
        let mut diagnostics = Vec::new();
        let owner_key = owner_key_from_entity(owner);
        match &declaration.kind {
            DeclarationKind::Struct(declared) => {
                for field in &declared.item.fields {
                    let id = source_id(
                        module,
                        source,
                        field.name.span,
                        Namespace::Member,
                        EntityKind::Field,
                        &field.name.text,
                        Some(owner_key.clone()),
                    );
                    if let Some(diagnostic) = self.insert_member(
                        owner,
                        id,
                        field.visibility.is_some(),
                        EntityShape::Plain,
                    ) {
                        diagnostics.push(diagnostic);
                    }
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Enum(declared) => {
                for variant in &declared.item.variants {
                    let shape = match &variant.fields {
                        VariantFields::Unit => EntityShape::ConstructorUnit,
                        VariantFields::Positional(_) => EntityShape::ConstructorPositional,
                        VariantFields::Named(_) => EntityShape::ConstructorNamed,
                    };
                    let variant_id = source_id(
                        module,
                        source,
                        variant.name.span,
                        Namespace::Value,
                        EntityKind::EnumConstructor,
                        &variant.name.text,
                        Some(owner_key.clone()),
                    );
                    if let Some(diagnostic) = self.insert_member(
                        owner,
                        variant_id.clone(),
                        owner_public(self, owner),
                        shape,
                    ) {
                        diagnostics.push(diagnostic);
                    }
                    let variant_owner = owner_key_from_entity(&variant_id);
                    match &variant.fields {
                        VariantFields::Unit => {}
                        VariantFields::Positional(fields) => {
                            for (index, field) in fields.iter().enumerate() {
                                let id = source_id(
                                    module,
                                    source,
                                    field.span,
                                    Namespace::Member,
                                    EntityKind::Field,
                                    &format!("#{index}"),
                                    Some(variant_owner.clone()),
                                );
                                if let Some(diagnostic) =
                                    self.insert_member(&variant_id, id, true, EntityShape::Plain)
                                {
                                    diagnostics.push(diagnostic);
                                }
                            }
                        }
                        VariantFields::Named(fields) => {
                            for field in fields {
                                let id = source_id(
                                    module,
                                    source,
                                    field.name.span,
                                    Namespace::Member,
                                    EntityKind::Field,
                                    &field.name.text,
                                    Some(variant_owner.clone()),
                                );
                                if let Some(diagnostic) =
                                    self.insert_member(&variant_id, id, true, EntityShape::Plain)
                                {
                                    diagnostics.push(diagnostic);
                                }
                            }
                        }
                    }
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Trait(declared) => {
                for member in &declared.item.members {
                    let (name, namespace, kind) = match &member.kind {
                        TraitMemberKind::Method(method) => {
                            (&method.name, Namespace::Value, EntityKind::Method)
                        }
                        TraitMemberKind::AssociatedType(associated) => (
                            &associated.name,
                            Namespace::Type,
                            EntityKind::AssociatedType,
                        ),
                    };
                    let id = source_id(
                        module,
                        source,
                        name.span,
                        namespace,
                        kind,
                        &name.text,
                        Some(owner_key.clone()),
                    );
                    if let Some(diagnostic) =
                        self.insert_member(owner, id, owner_public(self, owner), EntityShape::Plain)
                    {
                        diagnostics.push(diagnostic);
                    }
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Effect(declared) => {
                for operation in &declared.item.operations {
                    let id = source_id(
                        module,
                        source,
                        operation.name.span,
                        Namespace::Value,
                        EntityKind::EffectOperation,
                        &operation.name.text,
                        Some(owner_key.clone()),
                    );
                    if let Some(diagnostic) =
                        self.insert_member(owner, id, owner_public(self, owner), EntityShape::Plain)
                    {
                        diagnostics.push(diagnostic);
                    }
                }
            }
            _ => {}
        }
        diagnostics
    }

    fn index_impl_members(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        declaration: &Declaration,
    ) -> Vec<ProjectDiagnostic> {
        let (members, owner_kind) = match &declaration.kind {
            DeclarationKind::InherentImpl(implementation) => {
                (&implementation.members, EntityKind::InherentImpl)
            }
            DeclarationKind::TraitImpl(implementation) => {
                (&implementation.members, EntityKind::TraitImpl)
            }
            _ => return Vec::new(),
        };
        let mut diagnostics = Vec::new();
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span: declaration.span,
            kind: owner_kind,
            name: "impl".to_owned(),
        };
        let impl_identity = impl_id(module, source, declaration.span, owner_kind);
        self.entities.insert(
            impl_identity.clone(),
            Entity {
                declared_at: Some(OriginRef {
                    library: module.library(),
                    source: source.clone(),
                    span: declaration.span,
                }),
                public: false,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
        let mut seen = BTreeMap::<(Namespace, String), OriginRef>::new();
        for member in members {
            let (name, namespace, kind) = match &member.kind {
                ImplMemberKind::Function(function) => {
                    (&function.name, Namespace::Value, EntityKind::Method)
                }
                ImplMemberKind::AssociatedType(associated) => (
                    &associated.name,
                    Namespace::Type,
                    EntityKind::AssociatedType,
                ),
            };
            let origin = OriginRef {
                library: module.library(),
                source: source.clone(),
                span: name.span,
            };
            let key = (namespace, name.text.clone());
            if let Some(previous) = seen.get(&key) {
                diagnostics.push(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::MemberConflict {
                        name: name.text.clone(),
                    },
                    primary: Some(origin.clone()),
                    related: vec![previous.clone()],
                });
            } else {
                seen.insert(key, origin.clone());
            }
            let id = source_id(
                module,
                source,
                name.span,
                namespace,
                kind,
                &name.text,
                Some(owner.clone()),
            );
            diagnostics.extend(type_declaration_name_diagnostic(&id));
            self.entities
                .get_mut(&impl_identity)
                .expect("impl owner indexed")
                .members
                .entry(id.name.clone())
                .or_default()
                .push(id.clone());
            self.entities.insert(
                id,
                Entity {
                    declared_at: Some(origin),
                    public: member.visibility.is_some(),
                    owner: Some(impl_identity.clone()),
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
        }
        self.insert_impl_self(module, source, declaration.span, owner_kind);
        diagnostics
    }

    fn insert_member(
        &mut self,
        owner: &EntityId,
        id: EntityId,
        public: bool,
        shape: EntityShape,
    ) -> Option<ProjectDiagnostic> {
        let declared_at = match &id.site {
            EntitySite::Source(origin) => Some(origin.clone()),
            EntitySite::Language | EntitySite::Module(_) => None,
        };
        let existing = self
            .entities
            .get(owner)
            .and_then(|entity| entity.members.get(&id.name))
            .into_iter()
            .flatten()
            .find(|candidate| candidate.namespace == id.namespace)
            .cloned();
        let diagnostic = type_declaration_name_diagnostic(&id).or_else(|| {
            existing.map(|existing| ProjectDiagnostic {
                kind: ProjectDiagnosticKind::MemberConflict {
                    name: id.name.clone(),
                },
                primary: declared_at.clone(),
                related: self
                    .entities
                    .get(&existing)
                    .and_then(|entity| entity.declared_at.clone())
                    .into_iter()
                    .collect(),
            })
        });
        self.entities.insert(
            id.clone(),
            Entity {
                declared_at,
                public,
                owner: Some(owner.clone()),
                members: BTreeMap::new(),
                shape,
            },
        );
        self.entities
            .get_mut(owner)
            .expect("member owner is indexed before its members")
            .members
            .entry(id.name.clone())
            .or_default()
            .push(id);
        diagnostic
    }

    fn insert_self_entity(&mut self, module: &ModuleRef, source: &SourceRef, owner: &EntityId) {
        let id = source_id(
            module,
            source,
            owner_site_span(owner),
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner_key_from_entity(owner)),
        );
        self.entities.insert(
            id,
            Entity {
                declared_at: None,
                public: false,
                owner: Some(owner.clone()),
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn insert_impl_self(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        span: Span,
        kind: EntityKind,
    ) {
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span,
            kind,
            name: "impl".to_owned(),
        };
        let id = source_id(
            module,
            source,
            span,
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner),
        );
        self.entities.insert(
            id,
            Entity {
                declared_at: None,
                public: false,
                owner: Some(impl_id(module, source, span, kind)),
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn resolve_imports(&mut self) -> Result<(), ProjectDiagnostic> {
        loop {
            let mut changed = false;
            for index in 0..self.imports.len() {
                let outcome = {
                    let directive = &self.imports[index];
                    self.lookup_import_path(&directive.module, &directive.path)
                };
                let directive = &mut self.imports[index];
                if directive.invalid.is_none() {
                    directive.invalid = outcome.invalid;
                }
                let old_candidates = directive.candidates.len();
                let old_inaccessible = directive.inaccessible.len();
                directive.candidates.extend(outcome.accessible);
                directive.inaccessible.extend(outcome.inaccessible);
                changed |= directive.candidates.len() != old_candidates
                    || directive.inaccessible.len() != old_inaccessible;

                let deliveries = directive.candidates.iter().cloned().collect::<Vec<_>>();
                for target in deliveries {
                    let namespace = target.namespace;
                    if namespace == Namespace::Member {
                        continue;
                    }
                    let table = self.bindings.entry(directive.module.clone()).or_default();
                    let key = (namespace, directive.local_name.clone());
                    let entry = table.entry(key).or_default();
                    if let Some(existing) = entry.get_mut(&target) {
                        let was_public = existing.public;
                        existing.public |= directive.public;
                        changed |= existing.public != was_public;
                    } else {
                        entry.insert(
                            target.clone(),
                            Delivery {
                                target,
                                public: directive.public,
                                owner_module: directive.module.clone(),
                                origin: Some(directive.origin.clone()),
                            },
                        );
                        changed = true;
                    }
                }
            }
            if !changed {
                break;
            }
        }

        let mut diagnostics = self.import_directive_diagnostics();
        for (module, table) in &self.bindings {
            if let Some(diagnostic) = first_binding_diagnostic(self.core, module, table) {
                diagnostics.push((module.clone(), diagnostic));
            }
        }
        diagnostics.extend(self.constructor_owner_diagnostics());
        if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
            return Err(diagnostic);
        }
        Ok(())
    }

    fn lookup_import_path(&self, module: &ModuleRef, path: &Path) -> LookupOutcome {
        self.lookup_global_path(module, module, path)
    }

    fn lookup_global_path(
        &self,
        current: &ModuleRef,
        requester: &ModuleRef,
        path: &Path,
    ) -> LookupOutcome {
        let Some((mut containers, start, anchored)) = self.lookup_path_start(current, path) else {
            return LookupOutcome::invalid(ProjectDiagnosticKind::InvalidPath);
        };
        if containers.escaped_root {
            return LookupOutcome::invalid(ProjectDiagnosticKind::PathEscapesRoot);
        }
        if start == path.segments.len() {
            let mut outcome = LookupOutcome::default();
            for container in containers.accessible {
                if let LookupContainer::Module(module) = container
                    && let Some(id) = module_entity(&module)
                {
                    outcome.accessible.insert(id);
                }
            }
            return outcome;
        }

        let mut inaccessible = BTreeSet::new();
        for (offset, segment) in path.segments[start..].iter().enumerate() {
            let PathSegment::Identifier(identifier) = segment else {
                return LookupOutcome::invalid(ProjectDiagnosticKind::InvalidPath);
            };
            let terminal = start + offset + 1 == path.segments.len();
            let include_language = !anchored && start == 0 && offset == 0;
            containers = self.lookup_container_members(
                &containers,
                requester,
                &identifier.text,
                include_language,
                terminal,
            );
            inaccessible.extend(containers.inaccessible.iter().filter_map(|container| {
                match container {
                    LookupContainer::Module(module) => module_entity(module),
                    LookupContainer::Entity(entity) => Some(entity.clone()),
                }
            }));
            if containers.accessible.is_empty() && containers.inaccessible.is_empty() {
                return LookupOutcome {
                    inaccessible,
                    ..LookupOutcome::default()
                };
            }
            if terminal {
                let mut outcome = LookupOutcome::default();
                for candidate in containers.accessible {
                    if let LookupContainer::Entity(id) = candidate {
                        outcome.accessible.insert(id);
                    }
                }
                outcome.inaccessible = inaccessible;
                return outcome;
            }
        }
        LookupOutcome::default()
    }

    fn lookup_path_start(
        &self,
        current: &ModuleRef,
        path: &Path,
    ) -> Option<(ContainerOutcome, usize, bool)> {
        let first = path.segments.first()?;
        match first {
            PathSegment::Super(_) => {
                let mut base = current.clone();
                let mut index = 0;
                while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                    let Some(parent) = base.parent() else {
                        return Some((ContainerOutcome::escaped(), index, true));
                    };
                    base = parent;
                    index += 1;
                }
                Some((ContainerOutcome::module(base), index, true))
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "root" =>
            {
                Some((
                    ContainerOutcome::module(ModuleRef::root(current.library())),
                    1,
                    true,
                ))
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "self" =>
            {
                Some((ContainerOutcome::module(current.clone()), 1, true))
            }
            PathSegment::Identifier(_) => {
                Some((ContainerOutcome::module(current.clone()), 0, false))
            }
        }
    }

    fn lookup_container_members(
        &self,
        containers: &ContainerOutcome,
        requester: &ModuleRef,
        name: &str,
        include_language: bool,
        terminal: bool,
    ) -> ContainerOutcome {
        let mut result = ContainerOutcome::default();
        for container in &containers.accessible {
            match container {
                LookupContainer::Module(module) => {
                    self.lookup_module_name(
                        module,
                        requester,
                        name,
                        include_language,
                        terminal,
                        &mut result,
                    );
                }
                LookupContainer::Entity(entity) => {
                    self.lookup_entity_member(entity, requester, name, terminal, &mut result);
                }
            }
        }
        result
    }

    fn lookup_module_name(
        &self,
        module: &ModuleRef,
        requester: &ModuleRef,
        name: &str,
        include_language: bool,
        terminal: bool,
        result: &mut ContainerOutcome,
    ) {
        if let Some(table) = self.bindings.get(module) {
            for ((namespace, spelling), deliveries) in table {
                if spelling != name || *namespace == Namespace::Member {
                    continue;
                }
                for delivery in deliveries.values() {
                    let accessible =
                        delivery.public || requester.is_descendant_of(&delivery.owner_module);
                    let target = if delivery.target.kind == EntityKind::Module && !terminal {
                        LookupContainer::Module(delivery.target.module.clone())
                    } else {
                        LookupContainer::Entity(delivery.target.clone())
                    };
                    if accessible {
                        result.accessible.insert(target);
                    } else {
                        result.inaccessible.insert(target);
                    }
                }
            }
        }
        if include_language {
            for entity in self.entities.keys() {
                if entity.module.is_language() && entity.owner.is_none() && entity.name == name {
                    result
                        .accessible
                        .insert(LookupContainer::Entity(entity.clone()));
                }
            }
            if let Some(entity) = self.core_bindings.get(name) {
                result
                    .accessible
                    .insert(LookupContainer::Entity(entity.clone()));
            }
        }
        if !terminal {
            result.retain_containers(&self.entities);
        }
    }

    fn lookup_entity_member(
        &self,
        entity: &EntityId,
        requester: &ModuleRef,
        name: &str,
        terminal: bool,
        result: &mut ContainerOutcome,
    ) {
        let Some(metadata) = self.entities.get(entity) else {
            return;
        };
        for target in metadata.members.get(name).into_iter().flatten() {
            let Some(target_metadata) = self.entities.get(target) else {
                continue;
            };
            let accessible = target_metadata.public || requester.is_descendant_of(&target.module);
            let container = LookupContainer::Entity(target.clone());
            if accessible {
                result.accessible.insert(container);
            } else {
                result.inaccessible.insert(container);
            }
        }
        if !terminal {
            result.retain_containers(&self.entities);
        }
    }

    fn import_directive_diagnostics(&self) -> Vec<(ModuleRef, ProjectDiagnostic)> {
        let mut diagnostics = Vec::new();
        for directive in &self.imports {
            if let Some(kind) = &directive.invalid {
                diagnostics.push((
                    directive.module.clone(),
                    ProjectDiagnostic {
                        kind: kind.clone(),
                        primary: Some(directive.origin.clone()),
                        related: Vec::new(),
                    },
                ));
                continue;
            }
            let path = path_text(&directive.path);
            if directive.candidates.is_empty() {
                let kind = if !directive.inaccessible.is_empty() {
                    ProjectDiagnosticKind::InaccessibleImport { path }
                } else if self.import_reaches_cycle(directive) {
                    ProjectDiagnosticKind::ImportCycle { path }
                } else {
                    ProjectDiagnosticKind::UnresolvedImport { path }
                };
                diagnostics.push((
                    directive.module.clone(),
                    ProjectDiagnostic {
                        kind,
                        primary: Some(directive.origin.clone()),
                        related: Vec::new(),
                    },
                ));
                continue;
            }
            if directive.candidates.len() > 1 {
                diagnostics.push((
                    directive.module.clone(),
                    ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::AmbiguousImport { path },
                        primary: Some(directive.origin.clone()),
                        related: declaration_origins(&directive.candidates, &self.entities),
                    },
                ));
                continue;
            }
            let target = directive
                .candidates
                .first()
                .expect("nonempty import candidate set");
            if directive.public
                && !self
                    .entities
                    .get(target)
                    .is_some_and(|entity| entity.public)
            {
                diagnostics.push((
                    directive.module.clone(),
                    ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::PrivateReExport {
                            name: directive.local_name.clone(),
                        },
                        primary: Some(directive.origin.clone()),
                        related: self
                            .entities
                            .get(target)
                            .and_then(|entity| entity.declared_at.clone())
                            .into_iter()
                            .collect(),
                    },
                ));
            }
        }
        diagnostics
    }

    fn import_reaches_cycle(&self, directive: &ImportDirective) -> bool {
        let mut visiting = BTreeSet::new();
        let mut visited = BTreeSet::new();
        self.import_dependency_cycle(directive, &mut visiting, &mut visited)
    }

    fn import_dependency_cycle(
        &self,
        directive: &ImportDirective,
        visiting: &mut BTreeSet<(ModuleRef, Span)>,
        visited: &mut BTreeSet<(ModuleRef, Span)>,
    ) -> bool {
        let key = (directive.module.clone(), directive.origin.span);
        if visiting.contains(&key) {
            return true;
        }
        if !visited.insert(key.clone()) {
            return false;
        }
        visiting.insert(key.clone());
        for dependency in self.import_dependencies(directive) {
            if self.import_dependency_cycle(dependency, visiting, visited) {
                return true;
            }
        }
        visiting.remove(&key);
        false
    }

    fn import_dependencies<'a>(&'a self, directive: &ImportDirective) -> Vec<&'a ImportDirective> {
        let Some(last_name) = path_terminal_name(&directive.path) else {
            return Vec::new();
        };
        let mut prefix = directive.path.clone();
        prefix.segments.pop();
        if prefix.segments.is_empty() {
            return self
                .imports
                .iter()
                .filter(|candidate| {
                    candidate.module == directive.module && candidate.local_name == last_name
                })
                .collect();
        }
        prefix.span.end = prefix
            .segments
            .last()
            .map(path_segment_span)
            .map_or(prefix.span.start, |span| span.end);
        let outcome = self.lookup_global_path(&directive.module, &directive.module, &prefix);
        outcome
            .accessible
            .iter()
            .filter(|entity| entity.kind == EntityKind::Module)
            .flat_map(|entity| {
                self.imports.iter().filter(|candidate| {
                    candidate.module == entity.module && candidate.local_name == last_name
                })
            })
            .collect()
    }

    fn constructor_owner_diagnostics(&self) -> Vec<(ModuleRef, ProjectDiagnostic)> {
        let mut diagnostics = Vec::new();
        for (module, table) in &self.bindings {
            let public_types = table
                .iter()
                .filter(|((namespace, _), _)| *namespace == Namespace::Type)
                .flat_map(|(_, deliveries)| deliveries.values())
                .filter(|delivery| delivery.public)
                .map(|delivery| delivery.target.clone())
                .collect::<BTreeSet<_>>();
            for directive in self
                .imports
                .iter()
                .filter(|directive| directive.module == *module && directive.public)
            {
                let Some(target) = directive.candidates.first() else {
                    continue;
                };
                if directive.candidates.len() != 1
                    || !matches!(target.kind, EntityKind::EnumConstructor)
                {
                    continue;
                }
                let owner = self
                    .entities
                    .get(target)
                    .and_then(|entity| entity.owner.as_ref());
                if owner.is_some_and(|owner| !public_types.contains(owner)) {
                    diagnostics.push((
                        module.clone(),
                        ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::MissingConstructorOwner {
                                constructor: target.name.clone(),
                            },
                            primary: Some(directive.origin.clone()),
                            related: owner
                                .and_then(|owner| self.entities.get(owner))
                                .and_then(|entity| entity.declared_at.clone())
                                .into_iter()
                                .collect(),
                        },
                    ));
                }
            }
        }
        diagnostics
    }

    fn resolve_bodies(mut self) -> Result<ResolvedProject, ProjectDiagnostic> {
        let module_inputs = std::mem::take(&mut self.modules);
        let mut resolved_modules = Vec::new();
        let mut diagnostics = Vec::new();
        for (module, info) in module_inputs {
            let body = info.body;
            let resolved_body = if let Some(body) = body {
                let imports = self
                    .imports
                    .iter()
                    .filter(|directive| directive.module == module)
                    .map(|directive| ResolvedImport {
                        origin: directive.origin.clone(),
                        public: directive.public,
                        local_name: directive.local_name.clone(),
                        target: directive
                            .candidates
                            .first()
                            .expect("imports are validated before bodies")
                            .clone(),
                    })
                    .collect();
                let mut failed = false;
                let requires = match body.requires.as_ref() {
                    Some(effects) => {
                        let mut resolver =
                            BodyResolver::new(&mut self, module.clone(), body.origin.clone());
                        match resolver.resolve_effect_set(effects) {
                            Ok(effects) => Some(effects),
                            Err(diagnostic) => {
                                failed = true;
                                diagnostics.push((module.clone(), diagnostic));
                                None
                            }
                        }
                    }
                    None => None,
                };
                let mut declarations = Vec::new();
                for declaration in &body.declarations {
                    let mut resolver =
                        BodyResolver::new(&mut self, module.clone(), body.origin.clone());
                    match resolver.resolve_declaration(declaration) {
                        Ok(declaration) => declarations.push(declaration),
                        Err(diagnostic) => {
                            failed = true;
                            diagnostics.push((module.clone(), diagnostic));
                        }
                    }
                }
                (!failed).then_some(ResolvedModuleBody {
                    origin: OriginRef {
                        library: module.library(),
                        source: body.origin,
                        span: body.span,
                    },
                    requires,
                    imports,
                    declarations,
                })
            } else {
                None
            };
            resolved_modules.push((
                module,
                ResolvedModule {
                    body: resolved_body,
                },
            ));
        }
        if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
            return Err(diagnostic);
        }
        let modules = resolved_modules.into_iter().collect::<BTreeMap<_, _>>();
        let name_bindings = self
            .bindings
            .iter()
            .map(|(module, table)| {
                let table = table
                    .iter()
                    .map(|(name, deliveries)| {
                        let bindings = deliveries
                            .values()
                            .map(|delivery| ResolvedNameBinding {
                                target: delivery.target.clone(),
                                public: delivery.public,
                            })
                            .collect();
                        (name.clone(), bindings)
                    })
                    .collect();
                (module.clone(), table)
            })
            .collect();
        let core_roles = self
            .core_roles
            .take()
            .expect("core roles are indexed before body resolution");
        validate_core_profile(self.core, &modules, &core_roles)?;
        Ok(ResolvedProject {
            entry: self.entry,
            core: self.core,
            dependencies: self.dependencies,
            modules,
            entities: self.entities,
            core_roles,
            name_bindings,
        })
    }
}

fn validate_core_profile(
    core: LibraryId,
    modules: &BTreeMap<ModuleRef, ResolvedModule>,
    roles: &CoreRoles,
) -> Result<(), ProjectDiagnostic> {
    let body = modules
        .get(&ModuleRef::root(core))
        .and_then(|module| module.body.as_ref())
        .expect("the resolved core root always has a body");

    let option = resolved_core_declaration(body, &roles.option.declaration);
    let ResolvedDeclarationKind::Enum {
        type_parameters,
        variants,
    } = &option.kind
    else {
        unreachable!("the core declaration category was checked before body resolution")
    };
    let option_parameter = &type_parameters[0].binding.identity;
    let some = variants
        .iter()
        .find(|variant| variant.identity == roles.option.some)
        .expect("the indexed Option::Some variant is resolved");
    let some_payload_valid = matches!(
        &some.fields,
        ResolvedVariantFields::Positional(fields)
            if fields.len() == 1 && resolved_type_is_exact(&fields[0], option_parameter)
    );
    if !some_payload_valid {
        return Err(core_role_diagnostic(
            core,
            "Option",
            Some("Some"),
            CoreRoleIssue::VariantPayload,
            &roles.option.some,
        ));
    }
    let none = variants
        .iter()
        .find(|variant| variant.identity == roles.option.none)
        .expect("the indexed Option::None variant is resolved");
    if !matches!(none.fields, ResolvedVariantFields::Unit) {
        return Err(core_role_diagnostic(
            core,
            "Option",
            Some("None"),
            CoreRoleIssue::VariantPayload,
            &roles.option.none,
        ));
    }

    let ordering = resolved_core_declaration(body, &roles.ordering.declaration);
    let ResolvedDeclarationKind::Enum { variants, .. } = &ordering.kind else {
        unreachable!("the core declaration category was checked before body resolution")
    };
    for (name, identity) in [
        ("Less", &roles.ordering.less),
        ("Equal", &roles.ordering.equal),
        ("Greater", &roles.ordering.greater),
    ] {
        let variant = variants
            .iter()
            .find(|variant| variant.identity == *identity)
            .expect("the indexed Ordering variant is resolved");
        if !matches!(variant.fields, ResolvedVariantFields::Unit) {
            return Err(core_role_diagnostic(
                core,
                "Ordering",
                Some(name),
                CoreRoleIssue::VariantPayload,
                identity,
            ));
        }
    }

    let partial_eq_members = validate_core_trait_supertraits(
        core,
        body,
        "PartialEq",
        &roles.partial_eq.declaration,
        &[],
    )?;
    let eq_members = validate_core_trait_supertraits(
        core,
        body,
        "Eq",
        &roles.eq,
        &[&roles.partial_eq.declaration],
    )?;
    debug_assert!(eq_members.is_empty());
    let partial_ord_members = validate_core_trait_supertraits(
        core,
        body,
        "PartialOrd",
        &roles.partial_ord.declaration,
        &[&roles.partial_eq.declaration],
    )?;
    let ord_members = validate_core_trait_supertraits(
        core,
        body,
        "Ord",
        &roles.ord.declaration,
        &[&roles.eq, &roles.partial_ord.declaration],
    )?;
    let clone_members =
        validate_core_trait_supertraits(core, body, "Clone", &roles.clone.declaration, &[])?;
    let copy_members = validate_core_trait_supertraits(
        core,
        body,
        "Copy",
        &roles.copy,
        &[&roles.clone.declaration],
    )?;
    debug_assert!(copy_members.is_empty());
    let drop_members =
        validate_core_trait_supertraits(core, body, "Drop", &roles.drop.declaration, &[])?;
    let display_members =
        validate_core_trait_supertraits(core, body, "Display", &roles.display.declaration, &[])?;
    let debug_members =
        validate_core_trait_supertraits(core, body, "Debug", &roles.debug.declaration, &[])?;
    let hash_members =
        validate_core_trait_supertraits(core, body, "Hash", &roles.hash.declaration, &[])?;
    let fn_once_members =
        validate_core_trait_supertraits(core, body, "FnOnce", &roles.fn_once, &[])?;
    debug_assert!(fn_once_members.is_empty());
    let fn_mut_members =
        validate_core_trait_supertraits(core, body, "FnMut", &roles.fn_mut, &[&roles.fn_once])?;
    debug_assert!(fn_mut_members.is_empty());
    let fn_members =
        validate_core_trait_supertraits(core, body, "Fn", &roles.function, &[&roles.fn_mut])?;
    debug_assert!(fn_members.is_empty());
    let iterator_members =
        validate_core_trait_supertraits(core, body, "Iterator", &roles.iterator.declaration, &[])?;
    let iterable_members =
        validate_core_trait_supertraits(core, body, "Iterable", &roles.iterable.declaration, &[])?;

    let bool_type = language_id(Namespace::Type, EntityKind::LanguageType, "Bool", None);
    let unit_type = language_id(Namespace::Type, EntityKind::LanguageType, "Unit", None);
    let str_type = language_id(Namespace::Type, EntityKind::LanguageType, "Str", None);
    let int_type = language_id(Namespace::Type, EntityKind::LanguageType, "Int", None);

    let (parameters, result) = validate_core_method_header(
        core,
        "PartialEq",
        "eq",
        &roles.partial_eq.method,
        partial_eq_members,
        &[ParameterMode::Borrow, ParameterMode::Borrow],
        CoreMethodEffect::ClosedEmpty,
    )?;
    require_core_self_parameter(core, "PartialEq", "eq", &roles.partial_eq, 0, parameters[0])?;
    require_core_self_parameter(core, "PartialEq", "eq", &roles.partial_eq, 1, parameters[1])?;
    require_core_return_type(
        core,
        "PartialEq",
        "eq",
        &roles.partial_eq.method,
        result,
        |ty| resolved_type_is_exact(ty, &bool_type),
    )?;

    let (parameters, result) = validate_core_method_header(
        core,
        "PartialOrd",
        "partial_cmp",
        &roles.partial_ord.method,
        partial_ord_members,
        &[ParameterMode::Borrow, ParameterMode::Borrow],
        CoreMethodEffect::ClosedEmpty,
    )?;
    require_core_self_parameter(
        core,
        "PartialOrd",
        "partial_cmp",
        &roles.partial_ord,
        0,
        parameters[0],
    )?;
    require_core_self_parameter(
        core,
        "PartialOrd",
        "partial_cmp",
        &roles.partial_ord,
        1,
        parameters[1],
    )?;
    require_core_return_type(
        core,
        "PartialOrd",
        "partial_cmp",
        &roles.partial_ord.method,
        result,
        |ty| {
            resolved_type_is_unary_application(ty, &roles.option.declaration, |argument| {
                resolved_type_is_exact(argument, &roles.ordering.declaration)
            })
        },
    )?;

    let (parameters, result) = validate_core_method_header(
        core,
        "Ord",
        "cmp",
        &roles.ord.method,
        ord_members,
        &[ParameterMode::Borrow, ParameterMode::Borrow],
        CoreMethodEffect::ClosedEmpty,
    )?;
    require_core_self_parameter(core, "Ord", "cmp", &roles.ord, 0, parameters[0])?;
    require_core_self_parameter(core, "Ord", "cmp", &roles.ord, 1, parameters[1])?;
    require_core_return_type(core, "Ord", "cmp", &roles.ord.method, result, |ty| {
        resolved_type_is_exact(ty, &roles.ordering.declaration)
    })?;

    let (parameters, result) = validate_core_method_header(
        core,
        "Clone",
        "clone",
        &roles.clone.method,
        clone_members,
        &[ParameterMode::Borrow],
        CoreMethodEffect::Inferred,
    )?;
    require_core_self_parameter(core, "Clone", "clone", &roles.clone, 0, parameters[0])?;
    require_core_return_type(core, "Clone", "clone", &roles.clone.method, result, |ty| {
        resolved_type_is_self(ty, &roles.clone.declaration)
    })?;

    validate_simple_core_method(
        core,
        "Drop",
        "drop",
        &roles.drop,
        drop_members,
        ParameterMode::MutBorrow,
        &unit_type,
    )?;
    validate_simple_core_method(
        core,
        "Display",
        "to_str",
        &roles.display,
        display_members,
        ParameterMode::Borrow,
        &str_type,
    )?;
    validate_simple_core_method(
        core,
        "Debug",
        "debug",
        &roles.debug,
        debug_members,
        ParameterMode::Borrow,
        &str_type,
    )?;
    validate_simple_core_method(
        core,
        "Hash",
        "hash",
        &roles.hash,
        hash_members,
        ParameterMode::Borrow,
        &int_type,
    )?;

    let iterator_item =
        resolved_core_associated_type(iterator_members, &roles.iterator.item, "Iterator", core)?;
    if !iterator_item.0.is_empty() {
        return Err(core_role_diagnostic(
            core,
            "Iterator",
            Some("Item"),
            CoreRoleIssue::AssociatedTypeBounds,
            &roles.iterator.item,
        ));
    }
    if iterator_item.1.is_some() {
        return Err(core_role_diagnostic(
            core,
            "Iterator",
            Some("Item"),
            CoreRoleIssue::AssociatedTypeDefault,
            &roles.iterator.item,
        ));
    }
    let (parameters, result) = validate_core_method_header(
        core,
        "Iterator",
        "next",
        &roles.iterator.next,
        iterator_members,
        &[ParameterMode::MutBorrow],
        CoreMethodEffect::Inferred,
    )?;
    require_core_self_parameter(
        core,
        "Iterator",
        "next",
        &CoreMethodRole {
            declaration: roles.iterator.declaration.clone(),
            method: roles.iterator.next.clone(),
        },
        0,
        parameters[0],
    )?;
    require_core_return_type(
        core,
        "Iterator",
        "next",
        &roles.iterator.next,
        result,
        |ty| {
            resolved_type_is_unary_application(ty, &roles.option.declaration, |argument| {
                resolved_type_is_self_projection(
                    argument,
                    &roles.iterator.declaration,
                    &roles.iterator.item,
                )
            })
        },
    )?;

    let iterable_item =
        resolved_core_associated_type(iterable_members, &roles.iterable.item, "Iterable", core)?;
    if !iterable_item.0.is_empty() {
        return Err(core_role_diagnostic(
            core,
            "Iterable",
            Some("Item"),
            CoreRoleIssue::AssociatedTypeBounds,
            &roles.iterable.item,
        ));
    }
    if iterable_item.1.is_some() {
        return Err(core_role_diagnostic(
            core,
            "Iterable",
            Some("Item"),
            CoreRoleIssue::AssociatedTypeDefault,
            &roles.iterable.item,
        ));
    }
    let iterable_iter = resolved_core_associated_type(
        iterable_members,
        &roles.iterable.iter_type,
        "Iterable",
        core,
    )?;
    if iterable_iter.1.is_some() {
        return Err(core_role_diagnostic(
            core,
            "Iterable",
            Some("Iter"),
            CoreRoleIssue::AssociatedTypeDefault,
            &roles.iterable.iter_type,
        ));
    }
    if iterable_iter.0.len() != 1
        || !resolved_iterator_bound_matches(&iterable_iter.0[0], &roles.iterator, &roles.iterable)
    {
        return Err(core_role_diagnostic(
            core,
            "Iterable",
            Some("Iter"),
            CoreRoleIssue::AssociatedTypeBounds,
            &roles.iterable.iter_type,
        ));
    }
    let (parameters, result) = validate_core_method_header(
        core,
        "Iterable",
        "iter",
        &roles.iterable.iter,
        iterable_members,
        &[ParameterMode::Move],
        CoreMethodEffect::Inferred,
    )?;
    let iterable_method = CoreMethodRole {
        declaration: roles.iterable.declaration.clone(),
        method: roles.iterable.iter.clone(),
    };
    require_core_self_parameter(core, "Iterable", "iter", &iterable_method, 0, parameters[0])?;
    require_core_return_type(
        core,
        "Iterable",
        "iter",
        &roles.iterable.iter,
        result,
        |ty| {
            resolved_type_is_self_projection(
                ty,
                &roles.iterable.declaration,
                &roles.iterable.iter_type,
            )
        },
    )?;
    Ok(())
}

fn resolved_core_declaration<'a>(
    body: &'a ResolvedModuleBody,
    identity: &EntityId,
) -> &'a ResolvedDeclaration {
    body.declarations
        .iter()
        .find(|declaration| declaration.identity.as_ref() == Some(identity))
        .expect("every indexed core role has one resolved declaration")
}

fn validate_core_trait_supertraits<'a>(
    core: LibraryId,
    body: &'a ResolvedModuleBody,
    role: &str,
    identity: &EntityId,
    expected: &[&EntityId],
) -> Result<&'a [ResolvedTraitMember], ProjectDiagnostic> {
    let declaration = resolved_core_declaration(body, identity);
    let ResolvedDeclarationKind::Trait {
        supertraits,
        members,
        ..
    } = &declaration.kind
    else {
        unreachable!("the core declaration category was checked before body resolution")
    };
    let actual = supertraits
        .iter()
        .filter_map(|supertrait| {
            (supertrait.arguments.is_empty())
                .then(|| reference_exact_target(&supertrait.reference))
                .flatten()
                .cloned()
        })
        .collect::<BTreeSet<_>>();
    let expected = expected
        .iter()
        .map(|identity| (*identity).clone())
        .collect::<BTreeSet<_>>();
    if supertraits.len() != expected.len() || actual != expected {
        return Err(core_role_diagnostic(
            core,
            role,
            None,
            CoreRoleIssue::Supertraits,
            identity,
        ));
    }
    Ok(members)
}

#[derive(Clone, Copy)]
enum CoreMethodEffect {
    ClosedEmpty,
    Inferred,
}

fn validate_core_method_header<'a>(
    core: LibraryId,
    role: &str,
    member_name: &str,
    identity: &EntityId,
    members: &'a [ResolvedTraitMember],
    expected_modes: &[ParameterMode],
    expected_effect: CoreMethodEffect,
) -> Result<(Vec<&'a ResolvedType>, &'a ResolvedType), ProjectDiagnostic> {
    let member = members
        .iter()
        .find(|member| member.identity == *identity)
        .expect("every indexed core member is resolved");
    let ResolvedTraitMemberKind::Method(signature) = &member.kind else {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::MemberKind,
            identity,
        ));
    };
    if !signature.type_parameters.is_empty() || !signature.effect_parameters.is_empty() {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::MethodGenericArity {
                expected_types: 0,
                actual_types: signature.type_parameters.len(),
                expected_effects: 0,
                actual_effects: signature.effect_parameters.len(),
            },
            identity,
        ));
    }
    if signature.parameters.len() != expected_modes.len() {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::ParameterCount {
                expected: expected_modes.len(),
                actual: signature.parameters.len(),
            },
            identity,
        ));
    }
    if signature
        .parameters
        .first()
        .is_none_or(|parameter| parameter.binding.identity.name != "self")
    {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::Receiver,
            identity,
        ));
    }
    let mut parameter_types = Vec::new();
    for (index, (parameter, expected_mode)) in
        signature.parameters.iter().zip(expected_modes).enumerate()
    {
        let actual_mode = parameter.mode.map(|(_, mode)| mode);
        let effective_mode = actual_mode.unwrap_or(ParameterMode::Borrow);
        if parameter.escape.is_some() {
            return Err(core_role_diagnostic(
                core,
                role,
                Some(member_name),
                CoreRoleIssue::ParameterEscape { index },
                identity,
            ));
        }
        if effective_mode != *expected_mode {
            return Err(core_role_diagnostic(
                core,
                role,
                Some(member_name),
                CoreRoleIssue::ParameterMode {
                    index,
                    expected: *expected_mode,
                    actual: actual_mode,
                },
                identity,
            ));
        }
        let Some(ResolvedParameterAnnotation::Type(ty)) = parameter.annotation.as_ref() else {
            return Err(core_role_diagnostic(
                core,
                role,
                Some(member_name),
                CoreRoleIssue::ParameterType { index },
                identity,
            ));
        };
        parameter_types.push(ty);
    }
    let Some(result) = signature.return_type.as_ref() else {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::ReturnType,
            identity,
        ));
    };
    let valid_effect = match expected_effect {
        CoreMethodEffect::ClosedEmpty => signature
            .effects
            .as_ref()
            .is_some_and(|effects| effects.effects.is_empty()),
        CoreMethodEffect::Inferred => signature.effects.is_none(),
    };
    if !valid_effect {
        return Err(core_role_diagnostic(
            core,
            role,
            Some(member_name),
            CoreRoleIssue::EffectProfile,
            identity,
        ));
    }
    Ok((parameter_types, result))
}

fn require_core_self_parameter(
    core: LibraryId,
    role: &str,
    member: &str,
    method: &CoreMethodRole,
    index: usize,
    ty: &ResolvedType,
) -> Result<(), ProjectDiagnostic> {
    if resolved_type_is_self(ty, &method.declaration) {
        Ok(())
    } else {
        Err(core_role_diagnostic(
            core,
            role,
            Some(member),
            CoreRoleIssue::ParameterType { index },
            &method.method,
        ))
    }
}

fn require_core_return_type(
    core: LibraryId,
    role: &str,
    member: &str,
    identity: &EntityId,
    ty: &ResolvedType,
    matches: impl FnOnce(&ResolvedType) -> bool,
) -> Result<(), ProjectDiagnostic> {
    if matches(ty) {
        Ok(())
    } else {
        Err(core_role_diagnostic(
            core,
            role,
            Some(member),
            CoreRoleIssue::ReturnType,
            identity,
        ))
    }
}

fn validate_simple_core_method(
    core: LibraryId,
    role: &str,
    member: &str,
    method: &CoreMethodRole,
    members: &[ResolvedTraitMember],
    mode: ParameterMode,
    result_type: &EntityId,
) -> Result<(), ProjectDiagnostic> {
    let (parameters, result) = validate_core_method_header(
        core,
        role,
        member,
        &method.method,
        members,
        &[mode],
        CoreMethodEffect::Inferred,
    )?;
    require_core_self_parameter(core, role, member, method, 0, parameters[0])?;
    require_core_return_type(core, role, member, &method.method, result, |ty| {
        resolved_type_is_exact(ty, result_type)
    })
}

fn resolved_core_associated_type<'a>(
    members: &'a [ResolvedTraitMember],
    identity: &EntityId,
    role: &str,
    core: LibraryId,
) -> Result<(&'a [ResolvedNamedType], &'a Option<ResolvedType>), ProjectDiagnostic> {
    let member = members
        .iter()
        .find(|member| member.identity == *identity)
        .expect("every indexed core member is resolved");
    match &member.kind {
        ResolvedTraitMemberKind::AssociatedType { bounds, default } => Ok((bounds, default)),
        ResolvedTraitMemberKind::Method(_) => Err(core_role_diagnostic(
            core,
            role,
            Some(&identity.name),
            CoreRoleIssue::MemberKind,
            identity,
        )),
    }
}

fn resolved_iterator_bound_matches(
    bound: &ResolvedNamedType,
    iterator: &CoreIteratorRole,
    iterable: &CoreIterableRole,
) -> bool {
    if reference_exact_target(&bound.reference) != Some(&iterator.declaration)
        || bound.arguments.len() != 1
    {
        return false;
    }
    let ResolvedTypeArgument::AssociatedType { member, value } = &bound.arguments[0] else {
        return false;
    };
    member.declaration.as_ref() == Some(&iterator.item)
        && resolved_type_is_self_projection(value, &iterable.declaration, &iterable.item)
}

fn resolved_type_is_exact(ty: &ResolvedType, identity: &EntityId) -> bool {
    let Some(named) = resolved_named_type(ty) else {
        return false;
    };
    named.arguments.is_empty() && reference_exact_target(&named.reference) == Some(identity)
}

fn resolved_type_is_unary_application(
    ty: &ResolvedType,
    identity: &EntityId,
    argument_matches: impl FnOnce(&ResolvedType) -> bool,
) -> bool {
    let Some(named) = resolved_named_type(ty) else {
        return false;
    };
    if reference_exact_target(&named.reference) != Some(identity) || named.arguments.len() != 1 {
        return false;
    }
    let ResolvedTypeArgument::Type(argument) = &named.arguments[0] else {
        return false;
    };
    argument_matches(argument)
}

fn resolved_type_is_self(ty: &ResolvedType, owner: &EntityId) -> bool {
    let Some(named) = resolved_named_type(ty) else {
        return false;
    };
    named.arguments.is_empty()
        && reference_exact_target(&named.reference)
            .is_some_and(|identity| is_self_identity(identity, owner))
}

fn resolved_type_is_self_projection(
    ty: &ResolvedType,
    owner: &EntityId,
    member: &EntityId,
) -> bool {
    let Some(named) = resolved_named_type(ty) else {
        return false;
    };
    let ResolvedReference::Selection {
        base,
        members,
        self_reference,
        occurrence: _,
        namespace,
    } = &named.reference
    else {
        return false;
    };
    named.arguments.is_empty()
        && *namespace == Namespace::Type
        && (base == owner || is_self_identity(base, owner))
        && self_reference
            .as_ref()
            .is_none_or(|reference| is_self_identity(&reference.identity, owner))
        && members.len() == 1
        && members[0].declaration.as_ref() == Some(member)
}

fn resolved_named_type(ty: &ResolvedType) -> Option<&ResolvedNamedType> {
    match &ty.kind {
        ResolvedTypeKind::Named(named) => Some(named),
        ResolvedTypeKind::Grouped(inner) => resolved_named_type(inner),
        ResolvedTypeKind::Tuple(_) => None,
    }
}

fn is_self_identity(identity: &EntityId, owner: &EntityId) -> bool {
    identity.kind == EntityKind::SelfType
        && identity.module == owner.module
        && identity.owner.as_ref() == Some(&owner_key_from_entity(owner))
}

struct BodyResolver<'state> {
    state: &'state mut ResolverState,
    module: ModuleRef,
    source: SourceRef,
    type_scopes: Vec<BTreeMap<String, EntityId>>,
    effect_scopes: Vec<BTreeMap<String, EntityId>>,
    value_scopes: Vec<BTreeMap<String, EntityId>>,
    self_entity: Option<EntityId>,
    self_target: Option<ResolvedNamedType>,
    owner: OwnerKey,
}

impl<'state> BodyResolver<'state> {
    fn new(state: &'state mut ResolverState, module: ModuleRef, source: SourceRef) -> Self {
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span: Span::new(0, 0),
            kind: EntityKind::Module,
            name: module
                .path()
                .last()
                .cloned()
                .unwrap_or_else(|| "<root>".to_owned()),
        };
        Self {
            state,
            module,
            source,
            type_scopes: Vec::new(),
            effect_scopes: Vec::new(),
            value_scopes: Vec::new(),
            self_entity: None,
            self_target: None,
            owner,
        }
    }

    fn resolve_declaration(
        &mut self,
        declaration: &Declaration,
    ) -> Result<ResolvedDeclaration, ProjectDiagnostic> {
        let entity = match &declaration.kind {
            DeclarationKind::InherentImpl(_) => Some(impl_id(
                &self.module,
                &self.source,
                declaration.span,
                EntityKind::InherentImpl,
            )),
            DeclarationKind::TraitImpl(_) => Some(impl_id(
                &self.module,
                &self.source,
                declaration.span,
                EntityKind::TraitImpl,
            )),
            _ => declaration_entity(&self.module, &self.source, declaration).map(|value| value.0),
        };
        let public = match &declaration.kind {
            DeclarationKind::Function(declared) => declared.visibility.is_some(),
            DeclarationKind::Struct(declared) => declared.visibility.is_some(),
            DeclarationKind::Enum(declared) => declared.visibility.is_some(),
            DeclarationKind::Trait(declared) => declared.visibility.is_some(),
            DeclarationKind::Effect(declared) => declared.visibility.is_some(),
            DeclarationKind::EffectAlias(declared) => declared.visibility.is_some(),
            DeclarationKind::Extern(declared) => declared.visibility.is_some(),
            DeclarationKind::TypeAlias(declared) => declared.visibility.is_some(),
            DeclarationKind::Const(declared) => declared.visibility.is_some(),
            DeclarationKind::Module(declared) => declared.visibility.is_some(),
            DeclarationKind::InherentImpl(_) | DeclarationKind::TraitImpl(_) => false,
        };
        let kind = match &declaration.kind {
            DeclarationKind::Function(declared) => {
                let id = entity.as_ref().expect("function declaration is indexed");
                ResolvedDeclarationKind::Function(self.resolve_function(&declared.item, id)?)
            }
            DeclarationKind::Struct(declared) => {
                let id = entity.as_ref().expect("struct declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut fields = Vec::new();
                for field in &declared.item.fields {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        field.name.span,
                        Namespace::Member,
                        EntityKind::Field,
                        &field.name.text,
                        Some(owner.clone()),
                    );
                    fields.push(ResolvedField {
                        identity,
                        public: field.visibility.is_some(),
                        ty: self.resolve_type(&field.ty)?,
                    });
                }
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Struct {
                    type_parameters,
                    fields,
                }
            }
            DeclarationKind::Enum(declared) => {
                let id = entity.as_ref().expect("enum declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut variants = Vec::new();
                for variant in &declared.item.variants {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        variant.name.span,
                        Namespace::Value,
                        EntityKind::EnumConstructor,
                        &variant.name.text,
                        Some(owner.clone()),
                    );
                    let variant_owner = owner_key_from_entity(&identity);
                    let fields = match &variant.fields {
                        VariantFields::Unit => ResolvedVariantFields::Unit,
                        VariantFields::Positional(fields) => ResolvedVariantFields::Positional(
                            fields
                                .iter()
                                .map(|field| self.resolve_type(field))
                                .collect::<Result<Vec<_>, _>>()?,
                        ),
                        VariantFields::Named(fields) => {
                            let mut resolved = Vec::new();
                            for field in fields {
                                resolved.push(ResolvedNamedField {
                                    identity: source_id(
                                        &self.module,
                                        &self.source,
                                        field.name.span,
                                        Namespace::Member,
                                        EntityKind::Field,
                                        &field.name.text,
                                        Some(variant_owner.clone()),
                                    ),
                                    ty: self.resolve_type(&field.ty)?,
                                });
                            }
                            ResolvedVariantFields::Named(resolved)
                        }
                    };
                    variants.push(ResolvedVariant { identity, fields });
                }
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Enum {
                    type_parameters,
                    variants,
                }
            }
            DeclarationKind::InherentImpl(implementation) => {
                ResolvedDeclarationKind::InherentImpl(self.resolve_impl(
                    declaration.span,
                    EntityKind::InherentImpl,
                    &implementation.type_parameters,
                    &implementation.target,
                    &implementation.members,
                )?)
            }
            DeclarationKind::TraitImpl(implementation) => {
                let owner = self.impl_owner(declaration.span, EntityKind::TraitImpl);
                let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
                self.type_scopes
                    .push(self.impl_associated_type_scope(&implementation.members, &owner));
                let previous_self = self
                    .self_entity
                    .replace(self.self_id_for_impl(declaration.span, EntityKind::TraitImpl));
                let previous_self_target = self.self_target.take();
                let type_parameters =
                    self.push_type_parameters(&implementation.type_parameters, owner.clone())?;
                let trait_type = self.resolve_named_type(&implementation.trait_type)?;
                let target = self.resolve_named_type(&implementation.target)?;
                self.self_target = Some(target.clone());
                let where_clause = implementation
                    .where_clause
                    .as_ref()
                    .map(|clause| self.resolve_where_clause(clause))
                    .transpose()?;
                let members = self.resolve_impl_members(&implementation.members, &owner)?;
                self.self_entity = previous_self;
                self.self_target = previous_self_target;
                self.type_scopes.pop();
                self.type_scopes.pop();
                self.owner = previous_owner;
                ResolvedDeclarationKind::TraitImpl {
                    implementation: Box::new(ResolvedImpl {
                        type_parameters,
                        target,
                        members,
                    }),
                    trait_type,
                    where_clause,
                }
            }
            DeclarationKind::Trait(declared) => {
                let id = entity.as_ref().expect("trait declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let owner = owner_key_from_entity(id);
                self.type_scopes
                    .push(self.associated_type_scope(&declared.item.members, &owner));
                let type_parameters =
                    self.push_type_parameters(&declared.item.type_parameters, owner.clone())?;
                let supertraits = declared
                    .item
                    .supertraits
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?;
                let mut members = Vec::new();
                for member in &declared.item.members {
                    members.push(self.resolve_trait_member(member, id, &owner)?);
                }
                self.type_scopes.pop();
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Trait {
                    type_parameters,
                    supertraits,
                    members,
                }
            }
            DeclarationKind::Effect(declared) => {
                let id = entity.as_ref().expect("effect declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut operations = Vec::new();
                for operation in &declared.item.operations {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        operation.name.span,
                        Namespace::Value,
                        EntityKind::EffectOperation,
                        &operation.name.text,
                        Some(owner.clone()),
                    );
                    let (parameters, _) = self.resolve_parameters(
                        &operation.parameters,
                        owner_key_from_entity(&identity),
                    )?;
                    operations.push(ResolvedEffectOperation {
                        identity,
                        parameters,
                        return_type: self.resolve_type(&operation.return_type)?,
                    });
                }
                self.type_scopes.pop();
                ResolvedDeclarationKind::Effect {
                    type_parameters,
                    operations,
                }
            }
            DeclarationKind::EffectAlias(declared) => {
                let id = entity
                    .as_ref()
                    .expect("effect alias declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let effects = self.resolve_effect_set(&declared.item.effects)?;
                self.type_scopes.pop();
                ResolvedDeclarationKind::EffectAlias {
                    type_parameters,
                    effects,
                }
            }
            DeclarationKind::Extern(declared) => match &declared.item {
                ExternDeclaration::Function(function) => {
                    let id = entity
                        .as_ref()
                        .expect("extern function declaration is indexed");
                    ResolvedDeclarationKind::ExternFunction(
                        self.resolve_function_signature(function, id)?,
                    )
                }
                ExternDeclaration::Type {
                    type_parameters, ..
                } => {
                    let id = entity.as_ref().expect("extern type declaration is indexed");
                    let type_parameters =
                        self.push_type_parameters(type_parameters, owner_key_from_entity(id))?;
                    self.type_scopes.pop();
                    ResolvedDeclarationKind::ExternType { type_parameters }
                }
            },
            DeclarationKind::TypeAlias(declared) => {
                let id = entity.as_ref().expect("type alias declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let value = self.resolve_type(&declared.item.value)?;
                self.type_scopes.pop();
                ResolvedDeclarationKind::TypeAlias {
                    type_parameters,
                    value,
                }
            }
            DeclarationKind::Const(declared) => ResolvedDeclarationKind::Const {
                annotation: declared
                    .item
                    .annotation
                    .as_ref()
                    .map(|annotation| self.resolve_type(annotation))
                    .transpose()?,
                value: self.resolve_expr(&declared.item.value)?,
            },
            DeclarationKind::Module(declared) => {
                ResolvedDeclarationKind::Module(self.module.child(&declared.item.name.text))
            }
        };
        Ok(ResolvedDeclaration {
            origin: OriginRef {
                library: self.module.library(),
                source: self.source.clone(),
                span: declaration.span,
            },
            identity: entity,
            public,
            kind,
        })
    }

    fn resolve_impl(
        &mut self,
        span: Span,
        kind: EntityKind,
        parameters: &[TypeParameter],
        target: &NamedType,
        members: &[ImplMember],
    ) -> Result<ResolvedImpl, ProjectDiagnostic> {
        let owner = self.impl_owner(span, kind);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        self.type_scopes
            .push(self.impl_associated_type_scope(members, &owner));
        let previous_self = self.self_entity.replace(self.self_id_for_impl(span, kind));
        let previous_self_target = self.self_target.take();
        let type_parameters = self.push_type_parameters(parameters, owner.clone())?;
        let target = self.resolve_named_type(target)?;
        self.self_target = Some(target.clone());
        let members = self.resolve_impl_members(members, &owner)?;
        self.self_entity = previous_self;
        self.self_target = previous_self_target;
        self.type_scopes.pop();
        self.type_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedImpl {
            type_parameters,
            target,
            members,
        })
    }

    fn resolve_impl_members(
        &mut self,
        members: &[ImplMember],
        owner: &OwnerKey,
    ) -> Result<Vec<ResolvedImplMember>, ProjectDiagnostic> {
        let mut resolved = Vec::new();
        for member in members {
            let (identity, kind) = match &member.kind {
                ImplMemberKind::Function(function) => {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        function.name.span,
                        Namespace::Value,
                        EntityKind::Method,
                        &function.name.text,
                        Some(owner.clone()),
                    );
                    let function = self.resolve_function(function, &identity)?;
                    (identity, ResolvedImplMemberKind::Function(function))
                }
                ImplMemberKind::AssociatedType(associated) => {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    );
                    let value = self.resolve_type(&associated.value)?;
                    (identity, ResolvedImplMemberKind::AssociatedType(value))
                }
            };
            resolved.push(ResolvedImplMember {
                identity,
                public: member.visibility.is_some(),
                kind,
            });
        }
        Ok(resolved)
    }

    fn resolve_where_clause(
        &mut self,
        clause: &WhereClause,
    ) -> Result<ResolvedWhereClause, ProjectDiagnostic> {
        let mut predicates = Vec::new();
        for predicate in &clause.predicates {
            predicates.push(ResolvedWherePredicate {
                span: predicate.span,
                subject: self.resolve_type(&predicate.subject)?,
                bounds: predicate
                    .bounds
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?,
            });
        }
        Ok(ResolvedWhereClause {
            span: clause.span,
            keyword_span: clause.keyword_span,
            predicates,
        })
    }

    fn impl_associated_type_scope(
        &self,
        members: &[ImplMember],
        owner: &OwnerKey,
    ) -> BTreeMap<String, EntityId> {
        members
            .iter()
            .filter_map(|member| match &member.kind {
                ImplMemberKind::AssociatedType(associated) => Some((
                    associated.name.text.clone(),
                    source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    ),
                )),
                ImplMemberKind::Function(_) => None,
            })
            .collect()
    }

    fn resolve_trait_member(
        &mut self,
        member: &TraitMember,
        trait_id: &EntityId,
        owner: &OwnerKey,
    ) -> Result<ResolvedTraitMember, ProjectDiagnostic> {
        match &member.kind {
            TraitMemberKind::Method(method) => {
                let identity = source_id(
                    &self.module,
                    &self.source,
                    method.name.span,
                    Namespace::Value,
                    EntityKind::Method,
                    &method.name.text,
                    Some(owner.clone()),
                );
                Ok(ResolvedTraitMember {
                    identity: identity.clone(),
                    kind: ResolvedTraitMemberKind::Method(Box::new(
                        self.resolve_function_signature(method, &identity)?,
                    )),
                })
            }
            TraitMemberKind::AssociatedType(associated) => {
                let identity = source_id(
                    &self.module,
                    &self.source,
                    associated.name.span,
                    Namespace::Type,
                    EntityKind::AssociatedType,
                    &associated.name.text,
                    Some(owner.clone()),
                );
                let bounds = associated
                    .bounds
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?;
                let default = associated
                    .default
                    .as_ref()
                    .map(|default| self.resolve_type(default))
                    .transpose()?;
                debug_assert_eq!(
                    self.state
                        .entities
                        .get(&identity)
                        .and_then(|entity| entity.owner.as_ref()),
                    Some(trait_id)
                );
                Ok(ResolvedTraitMember {
                    identity,
                    kind: ResolvedTraitMemberKind::AssociatedType { bounds, default },
                })
            }
        }
    }

    fn associated_type_scope(
        &self,
        members: &[TraitMember],
        owner: &OwnerKey,
    ) -> BTreeMap<String, EntityId> {
        members
            .iter()
            .filter_map(|member| match &member.kind {
                TraitMemberKind::AssociatedType(associated) => Some((
                    associated.name.text.clone(),
                    source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    ),
                )),
                TraitMemberKind::Method(_) => None,
            })
            .collect()
    }

    fn resolve_function(
        &mut self,
        function: &FunctionDeclaration,
        identity: &EntityId,
    ) -> Result<ResolvedFunction, ProjectDiagnostic> {
        let owner = owner_key_from_entity(identity);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (type_parameters, effect_parameters) = self.push_callable_parameters(
            &function.type_parameters,
            &function.effect_parameters,
            owner.clone(),
        )?;
        let (parameters, value_scope) = self.resolve_parameters(&function.parameters, owner)?;
        let return_type = function
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_return_annotation(return_type).map(Box::new))
            .transpose()?;
        let effects = function
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.value_scopes.push(value_scope);
        let body = self.resolve_block(&function.body)?;
        self.value_scopes.pop();
        self.type_scopes.pop();
        self.effect_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedFunction {
            const_span: function.const_span,
            type_parameters,
            effect_parameters,
            parameters,
            return_type,
            effects,
            body,
        })
    }

    fn resolve_function_signature(
        &mut self,
        function: &FunctionSignature,
        identity: &EntityId,
    ) -> Result<ResolvedFunctionSignature, ProjectDiagnostic> {
        let owner = owner_key_from_entity(identity);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (type_parameters, effect_parameters) = self.push_callable_parameters(
            &function.type_parameters,
            &function.effect_parameters,
            owner.clone(),
        )?;
        let (parameters, _) = self.resolve_parameters(&function.parameters, owner)?;
        let return_type = function
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_type(return_type))
            .transpose()?;
        let effects = function
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.type_scopes.pop();
        self.effect_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedFunctionSignature {
            identity: identity.clone(),
            type_parameters,
            effect_parameters,
            parameters,
            return_type,
            effects,
        })
    }

    fn push_callable_parameters(
        &mut self,
        type_parameters: &[TypeParameter],
        effect_parameters: &[EffectParameter],
        owner: OwnerKey,
    ) -> Result<(Vec<ResolvedTypeParameter>, Vec<ResolvedEffectParameter>), ProjectDiagnostic> {
        // Effect formals must exist before type bounds resolve, but a later
        // binder error must not outrank an earlier bound diagnostic.
        let (effect_parameters, mut diagnostics) =
            self.push_effect_parameters(effect_parameters, owner.clone());
        let type_parameters = match self.push_type_parameters(type_parameters, owner) {
            Ok(parameters) => Some(parameters),
            Err(diagnostic) => {
                diagnostics.push((self.module.clone(), diagnostic));
                None
            }
        };
        if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
            if type_parameters.is_some() {
                self.type_scopes.pop();
            }
            self.effect_scopes.pop();
            return Err(diagnostic);
        }
        Ok((
            type_parameters.expect("type parameters are present without diagnostics"),
            effect_parameters,
        ))
    }

    fn push_type_parameters(
        &mut self,
        parameters: &[TypeParameter],
        owner: OwnerKey,
    ) -> Result<Vec<ResolvedTypeParameter>, ProjectDiagnostic> {
        let mut scope = BTreeMap::new();
        let mut valid_sites = BTreeSet::new();
        let mut diagnostics = Vec::new();
        for parameter in parameters {
            let origin = self.origin(parameter.name.span);
            let invalid = if parameter.name.text == "Self" {
                Some(self.diagnostic(
                    ProjectDiagnosticKind::InvalidSelf {
                        library: self.module.library(),
                    },
                    origin.clone(),
                ))
            } else if is_protected_name(Namespace::Type, &parameter.name.text) {
                Some(self.diagnostic(
                    ProjectDiagnosticKind::ReservedLanguageBinding {
                        library: self.module.library(),
                        namespace: NameNamespace::Type,
                        name: parameter.name.text.clone(),
                    },
                    origin.clone(),
                ))
            } else if let Some(existing) = scope.get(&parameter.name.text) {
                Some(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin.clone()),
                    related: entity_origin(existing).into_iter().collect(),
                })
            } else {
                self.type_scopes
                    .iter()
                    .rev()
                    .find_map(|scope| scope.get(&parameter.name.text))
                    .map(|existing| ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::DuplicateBinding {
                            name: parameter.name.text.clone(),
                        },
                        primary: Some(origin.clone()),
                        related: entity_origin(existing).into_iter().collect(),
                    })
            };
            if let Some(diagnostic) = invalid {
                diagnostics.push((self.module.clone(), diagnostic));
                continue;
            }
            let identity = source_id(
                &self.module,
                &self.source,
                parameter.name.span,
                Namespace::Type,
                EntityKind::TypeParameter,
                &parameter.name.text,
                Some(owner.clone()),
            );
            scope.insert(parameter.name.text.clone(), identity.clone());
            valid_sites.insert(parameter.name.span);
            self.insert_scoped_entity(identity);
        }
        self.type_scopes.push(scope.clone());
        let mut resolved = Vec::new();
        for parameter in parameters {
            if !valid_sites.contains(&parameter.name.span) {
                continue;
            }
            let mut bounds = Vec::new();
            let mut failed = false;
            for bound in &parameter.bounds {
                let result = match bound {
                    GenericBound::Named(bound) => self
                        .resolve_named_type(bound)
                        .map(Box::new)
                        .map(ResolvedGenericBound::Named),
                    GenericBound::Shape(bound) => {
                        self.resolve_shape(bound).map(ResolvedGenericBound::Shape)
                    }
                };
                match result {
                    Ok(bound) => bounds.push(bound),
                    Err(diagnostic) => {
                        failed = true;
                        diagnostics.push((self.module.clone(), diagnostic));
                        break;
                    }
                }
            }
            if failed {
                continue;
            }
            resolved.push(ResolvedTypeParameter {
                span: parameter.span,
                binding: ResolvedBinding {
                    origin: self.origin(parameter.name.span),
                    identity: scope
                        .get(&parameter.name.text)
                        .expect("type parameter was inserted")
                        .clone(),
                },
                bounds,
            });
        }
        if let Some(diagnostic) = first_stage_diagnostic(diagnostics) {
            self.type_scopes.pop();
            return Err(diagnostic);
        }
        Ok(resolved)
    }

    fn push_effect_parameters(
        &mut self,
        parameters: &[EffectParameter],
        owner: OwnerKey,
    ) -> (
        Vec<ResolvedEffectParameter>,
        Vec<(ModuleRef, ProjectDiagnostic)>,
    ) {
        let mut scope = BTreeMap::new();
        let mut resolved = Vec::new();
        let mut diagnostics = Vec::new();
        for parameter in parameters {
            let origin = self.origin(parameter.name.span);
            let invalid = if is_protected_name(Namespace::Effect, &parameter.name.text) {
                Some(self.diagnostic(
                    ProjectDiagnosticKind::ReservedLanguageBinding {
                        library: self.module.library(),
                        namespace: NameNamespace::Effect,
                        name: parameter.name.text.clone(),
                    },
                    origin.clone(),
                ))
            } else if let Some(existing) = scope.get(&parameter.name.text) {
                Some(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin.clone()),
                    related: entity_origin(existing).into_iter().collect(),
                })
            } else {
                self.effect_scopes
                    .iter()
                    .rev()
                    .find_map(|scope| scope.get(&parameter.name.text))
                    .map(|existing| ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::DuplicateBinding {
                            name: parameter.name.text.clone(),
                        },
                        primary: Some(origin.clone()),
                        related: entity_origin(existing).into_iter().collect(),
                    })
            };
            if let Some(diagnostic) = invalid {
                diagnostics.push((self.module.clone(), diagnostic));
                continue;
            }
            let identity = source_id(
                &self.module,
                &self.source,
                parameter.name.span,
                Namespace::Effect,
                EntityKind::EffectParameter,
                &parameter.name.text,
                Some(owner.clone()),
            );
            scope.insert(parameter.name.text.clone(), identity.clone());
            self.insert_scoped_entity(identity.clone());
            resolved.push(ResolvedEffectParameter {
                span: parameter.span,
                binding: ResolvedBinding { origin, identity },
            });
        }
        self.effect_scopes.push(scope);
        (resolved, diagnostics)
    }

    fn resolve_parameters(
        &mut self,
        parameters: &[NamedParameter],
        owner: OwnerKey,
    ) -> Result<(Vec<ResolvedParameter>, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut scope = BTreeMap::new();
        let mut resolved = Vec::new();
        for parameter in parameters {
            let origin = self.origin(parameter.name.span);
            let identity = source_id(
                &self.module,
                &self.source,
                parameter.name.span,
                Namespace::Value,
                EntityKind::Parameter,
                &parameter.name.text,
                Some(owner.clone()),
            );
            if let Some(existing) = scope.insert(parameter.name.text.clone(), identity.clone()) {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin),
                    related: entity_origin(&existing).into_iter().collect(),
                });
            }
            self.insert_scoped_entity(identity.clone());
            let (escape, mode, annotation) = match &parameter.annotation {
                Some(annotation) => {
                    let resolved = match &annotation.kind {
                        ParameterTypeKind::Type(ty) => {
                            ResolvedParameterAnnotation::Type(self.resolve_type(ty)?)
                        }
                        ParameterTypeKind::Shape(shape) => {
                            ResolvedParameterAnnotation::Shape(self.resolve_shape(shape)?)
                        }
                    };
                    (
                        annotation.escape.map(|escape| escape.span),
                        annotation.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                        Some(resolved),
                    )
                }
                None => (None, None, None),
            };
            resolved.push(ResolvedParameter {
                span: parameter.span,
                binding: ResolvedBinding { origin, identity },
                escape,
                mode,
                annotation,
            });
        }
        Ok((resolved, scope))
    }

    fn insert_scoped_entity(&mut self, identity: EntityId) {
        let declared_at = entity_origin(&identity);
        self.state.entities.insert(
            identity,
            Entity {
                declared_at,
                public: false,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn self_id_for_entity(&self, owner: &EntityId) -> EntityId {
        source_id(
            &self.module,
            &self.source,
            owner_site_span(owner),
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner_key_from_entity(owner)),
        )
    }

    fn self_id_for_impl(&self, span: Span, kind: EntityKind) -> EntityId {
        source_id(
            &self.module,
            &self.source,
            span,
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(self.impl_owner(span, kind)),
        )
    }

    fn impl_owner(&self, span: Span, kind: EntityKind) -> OwnerKey {
        OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span,
            kind,
            name: "impl".to_owned(),
        }
    }

    fn origin(&self, span: Span) -> OriginRef {
        OriginRef {
            library: self.module.library(),
            source: self.source.clone(),
            span,
        }
    }

    fn diagnostic(&self, kind: ProjectDiagnosticKind, primary: OriginRef) -> ProjectDiagnostic {
        ProjectDiagnostic {
            kind,
            primary: Some(primary),
            related: Vec::new(),
        }
    }
}

fn entity_origin(entity: &EntityId) -> Option<OriginRef> {
    match &entity.site {
        EntitySite::Source(origin) => Some(origin.clone()),
        EntitySite::Language | EntitySite::Module(_) => None,
    }
}

#[derive(Clone, PartialEq, Eq)]
enum PathCandidate {
    Module(ModuleRef),
    Exact(EntityId),
    Selection {
        base: EntityId,
        namespace: Namespace,
        members: Vec<ResolvedSelection>,
    },
}

impl PathCandidate {
    fn namespace(&self) -> Namespace {
        match self {
            Self::Module(_) => Namespace::Type,
            Self::Exact(entity) => entity.namespace,
            Self::Selection { namespace, .. } => *namespace,
        }
    }
}

fn path_candidate_from_reference(reference: &ResolvedReference) -> PathCandidate {
    match reference {
        ResolvedReference::Exact { target, .. } => PathCandidate::Exact(target.clone()),
        ResolvedReference::Selection {
            base,
            namespace,
            members,
            ..
        } => PathCandidate::Selection {
            base: base.clone(),
            namespace: *namespace,
            members: members.clone(),
        },
    }
}

#[derive(Default)]
struct BodyLookupOutcome {
    candidates: Vec<PathCandidate>,
    inaccessible: Vec<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
    self_reference: Option<ResolvedSelfReference>,
    missing_self_type: bool,
}

#[derive(Clone, Copy)]
enum ExpectedName {
    Type,
    Value,
    Effect,
    EffectApplication,
    Construct,
    PatternConstructor,
    MethodReceiver,
}

impl ExpectedName {
    fn namespace(self) -> NameNamespace {
        match self {
            Self::Type => NameNamespace::Type,
            Self::Effect | Self::EffectApplication => NameNamespace::Effect,
            Self::Value | Self::Construct | Self::PatternConstructor | Self::MethodReceiver => {
                NameNamespace::Value
            }
        }
    }

    fn accepts_exact(self, entity: &EntityId) -> bool {
        match self {
            Self::Type => entity.namespace == Namespace::Type && entity.kind != EntityKind::Module,
            Self::Value => entity.namespace == Namespace::Value,
            Self::Effect => entity.namespace == Namespace::Effect,
            Self::EffectApplication => {
                entity.namespace == Namespace::Effect
                    || entity.kind == EntityKind::Method
                        && entity
                            .owner
                            .as_ref()
                            .is_some_and(|owner| owner.kind == EntityKind::Trait)
            }
            Self::Construct => matches!(
                entity.kind,
                EntityKind::Struct | EntityKind::EnumConstructor
            ),
            Self::PatternConstructor => matches!(entity.kind, EntityKind::EnumConstructor),
            Self::MethodReceiver => {
                matches!(entity.namespace, Namespace::Value | Namespace::Effect)
            }
        }
    }

    fn accepts_selection_namespace(self, namespace: Namespace) -> bool {
        match self {
            Self::Type => namespace == Namespace::Type,
            Self::Value | Self::MethodReceiver => namespace == Namespace::Value,
            Self::Effect | Self::EffectApplication | Self::Construct | Self::PatternConstructor => {
                false
            }
        }
    }

    fn root_namespaces(self) -> &'static [Namespace] {
        match self {
            Self::Type => &[Namespace::Type],
            Self::Value => &[Namespace::Value],
            Self::Effect => &[Namespace::Effect],
            Self::EffectApplication => &[Namespace::Effect, Namespace::Type],
            Self::Construct => &[Namespace::Type, Namespace::Value],
            Self::PatternConstructor => &[Namespace::Value],
            Self::MethodReceiver => &[Namespace::Value, Namespace::Effect],
        }
    }
}

#[derive(Clone, Copy)]
enum PathRequirement {
    Container,
    Terminal(ExpectedName),
}

impl PathRequirement {
    fn at(segment_index: usize, segment_count: usize, expected: ExpectedName) -> Self {
        if segment_index + 1 == segment_count {
            Self::Terminal(expected)
        } else {
            Self::Container
        }
    }

    fn accepts_exact(self, entity: &EntityId) -> bool {
        match self {
            Self::Container => entity.kind == EntityKind::Module || is_selection_base(entity),
            Self::Terminal(expected) => expected.accepts_exact(entity),
        }
    }

    fn accepts_selection(self, namespace: Namespace) -> bool {
        match self {
            Self::Container => namespace == Namespace::Type,
            Self::Terminal(expected) => expected.accepts_selection_namespace(namespace),
        }
    }

    fn pending_namespace(self) -> Option<Namespace> {
        match self {
            Self::Container | Self::Terminal(ExpectedName::Type) => Some(Namespace::Type),
            Self::Terminal(ExpectedName::Value | ExpectedName::MethodReceiver) => {
                Some(Namespace::Value)
            }
            Self::Terminal(
                ExpectedName::Effect
                | ExpectedName::EffectApplication
                | ExpectedName::Construct
                | ExpectedName::PatternConstructor,
            ) => None,
        }
    }

    fn root_namespaces(self) -> &'static [Namespace] {
        match self {
            Self::Container => &[Namespace::Type],
            Self::Terminal(expected) => expected.root_namespaces(),
        }
    }
}

impl BodyResolver<'_> {
    fn resolve_type(&mut self, ty: &TypeExpr) -> Result<ResolvedType, ProjectDiagnostic> {
        let kind = match &ty.kind {
            TypeKind::Named(named) => {
                ResolvedTypeKind::Named(Box::new(self.resolve_named_type_parts(ty.span, named)?))
            }
            TypeKind::Grouped(inner) => {
                ResolvedTypeKind::Grouped(Box::new(self.resolve_type(inner)?))
            }
            TypeKind::Tuple(elements) => ResolvedTypeKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_type(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
        };
        Ok(ResolvedType {
            span: ty.span,
            kind,
        })
    }

    fn resolve_shape(&mut self, shape: &ShapeExpr) -> Result<ResolvedShape, ProjectDiagnostic> {
        let kind = match &shape.kind {
            ShapeKind::Callable(callable) => ResolvedShapeKind::Callable {
                parameters: callable
                    .parameters
                    .iter()
                    .map(|parameter| {
                        Ok(ResolvedShapeParameter {
                            span: parameter.span,
                            escape: parameter.escape.map(|escape| escape.span),
                            mode: parameter.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                            ty: self.resolve_type(&parameter.ty)?,
                        })
                    })
                    .collect::<Result<Vec<_>, ProjectDiagnostic>>()?,
                return_type: Box::new(self.resolve_type(&callable.return_type)?),
                effects: callable
                    .effects
                    .as_ref()
                    .map(|effects| self.resolve_effect_set(effects))
                    .transpose()?,
            },
            ShapeKind::Grouped(inner) => {
                ResolvedShapeKind::Grouped(Box::new(self.resolve_shape(inner)?))
            }
        };
        Ok(ResolvedShape {
            span: shape.span,
            kind,
        })
    }

    fn resolve_return_annotation(
        &mut self,
        annotation: &ReturnAnnotation,
    ) -> Result<ResolvedReturnAnnotation, ProjectDiagnostic> {
        match annotation {
            ReturnAnnotation::Type(ty) => self.resolve_type(ty).map(ResolvedReturnAnnotation::Type),
            ReturnAnnotation::Shape(shape) => self
                .resolve_shape(shape)
                .map(ResolvedReturnAnnotation::Shape),
        }
    }

    fn resolve_named_type(
        &mut self,
        ty: &NamedType,
    ) -> Result<ResolvedNamedType, ProjectDiagnostic> {
        self.resolve_named_type_parts(ty.span, &ty.kind)
    }

    fn resolve_named_type_parts(
        &mut self,
        span: Span,
        ty: &NamedTypeKind,
    ) -> Result<ResolvedNamedType, ProjectDiagnostic> {
        let reference = self.resolve_path(&ty.path, ExpectedName::Type)?;
        let mut arguments = Vec::new();
        for argument in &ty.arguments {
            arguments.push(match argument {
                TypeArgument::Type(ty) => {
                    ResolvedTypeArgument::Type(Box::new(self.resolve_type(ty)?))
                }
                TypeArgument::AssociatedType { name, value, .. } => {
                    ResolvedTypeArgument::AssociatedType {
                        member: Box::new(
                            self.associated_type_argument_for_reference(&reference, name)?,
                        ),
                        value: Box::new(self.resolve_type(value)?),
                    }
                }
            });
        }
        Ok(ResolvedNamedType {
            span,
            reference,
            arguments,
        })
    }

    fn resolve_effect_set(
        &mut self,
        set: &EffectSet,
    ) -> Result<ResolvedEffectSet, ProjectDiagnostic> {
        let effects = set
            .effects
            .iter()
            .map(|effect| self.resolve_effect(effect))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ResolvedEffectSet {
            span: set.span,
            effects,
        })
    }

    fn resolve_effect(&mut self, effect: &EffectExpr) -> Result<ResolvedEffect, ProjectDiagnostic> {
        let (reference, arguments, effect_arguments) = match &effect.kind {
            EffectKind::Named {
                path,
                arguments,
                effect_arguments,
            } => {
                let expected = if arguments.is_empty() && effect_arguments.is_empty() {
                    ExpectedName::Effect
                } else {
                    ExpectedName::EffectApplication
                };
                let reference = self.resolve_path(path, expected)?;
                let target = reference_exact_target(&reference)
                    .expect("effect expressions never retain type-dependent selection");
                if target.kind != EntityKind::Method && !effect_arguments.is_empty()
                    || target.kind == EntityKind::EffectParameter && !arguments.is_empty()
                {
                    return Err(self.diagnostic(
                        ProjectDiagnosticKind::UnresolvedName {
                            namespace: NameNamespace::Effect,
                            name: path_text(path),
                        },
                        self.origin(effect.span),
                    ));
                }
                (
                    reference,
                    arguments
                        .iter()
                        .map(|argument| self.resolve_type(argument))
                        .collect::<Result<Vec<_>, _>>()?,
                    effect_arguments
                        .iter()
                        .map(|argument| {
                            Ok(ResolvedEffectRowArgument {
                                span: argument.span,
                                effects: self.resolve_effect_set(&argument.effects)?,
                            })
                        })
                        .collect::<Result<Vec<_>, ProjectDiagnostic>>()?,
                )
            }
            EffectKind::Mutation => (
                ResolvedReference::Exact {
                    occurrence: self.origin(effect.span),
                    target: language_id(Namespace::Effect, EntityKind::LanguageEffect, "mut", None),
                    self_reference: None,
                },
                Vec::new(),
                Vec::new(),
            ),
            EffectKind::Unsafe => (
                ResolvedReference::Exact {
                    occurrence: self.origin(effect.span),
                    target: language_id(
                        Namespace::Effect,
                        EntityKind::LanguageEffect,
                        "unsafe",
                        None,
                    ),
                    self_reference: None,
                },
                Vec::new(),
                Vec::new(),
            ),
        };
        Ok(ResolvedEffect {
            span: effect.span,
            reference,
            arguments,
            effect_arguments,
        })
    }

    fn resolve_path(
        &self,
        path: &Path,
        expected: ExpectedName,
    ) -> Result<ResolvedReference, ProjectDiagnostic> {
        self.resolve_path_for_method(path, expected, None)
    }

    fn resolve_method_receiver_path(
        &self,
        path: &Path,
        method: &Identifier,
    ) -> Result<ResolvedReference, ProjectDiagnostic> {
        self.resolve_path_for_method(path, ExpectedName::MethodReceiver, Some(method))
    }

    fn resolve_path_for_method(
        &self,
        path: &Path,
        expected: ExpectedName,
        method: Option<&Identifier>,
    ) -> Result<ResolvedReference, ProjectDiagnostic> {
        let outcome = self.lookup_body_path(path, expected);
        if let Some(kind) = outcome.invalid {
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        let mut accepted = outcome.candidates;
        deduplicate_candidates(&mut accepted);
        if let Some(method) = method
            && accepted
                .iter()
                .any(|candidate| self.candidate_can_receive_method(candidate, &method.text))
        {
            accepted.retain(|candidate| self.candidate_can_receive_method(candidate, &method.text));
        }
        if accepted.is_empty() {
            let name = path_terminal_name(path).unwrap_or_else(|| path_text(path));
            let kind = if !outcome.inaccessible.is_empty() {
                ProjectDiagnosticKind::InaccessibleName { name }
            } else if outcome.missing_self_type {
                ProjectDiagnosticKind::InvalidSelf {
                    library: self.module.library(),
                }
            } else {
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: expected.namespace(),
                    name,
                }
            };
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        if accepted.len() > 1 {
            let related = accepted
                .iter()
                .filter_map(|candidate| match candidate {
                    PathCandidate::Exact(entity) => entity_origin(entity),
                    PathCandidate::Module(_) | PathCandidate::Selection { .. } => None,
                })
                .collect();
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::AmbiguousName {
                    name: path_text(path),
                },
                primary: Some(self.origin(path.span)),
                related,
            });
        }
        let self_reference = outcome.self_reference.map(Box::new);
        Ok(match accepted.pop().expect("one accepted path candidate") {
            PathCandidate::Exact(target) => ResolvedReference::Exact {
                occurrence: self.origin(path.span),
                target,
                self_reference,
            },
            PathCandidate::Selection {
                base,
                namespace,
                members,
            } => ResolvedReference::Selection {
                occurrence: self.origin(path.span),
                base,
                namespace,
                members,
                self_reference,
            },
            PathCandidate::Module(_) => unreachable!("modules do not match body name contexts"),
        })
    }

    fn candidate_can_receive_method(&self, candidate: &PathCandidate, method: &str) -> bool {
        let PathCandidate::Exact(entity) = candidate else {
            return true;
        };
        if entity.namespace != Namespace::Effect {
            return true;
        }
        matches!(entity.kind, EntityKind::Effect | EntityKind::LanguageEffect)
            && self
                .state
                .entities
                .get(entity)
                .and_then(|metadata| metadata.members.get(method))
                .into_iter()
                .flatten()
                .any(|member| member.kind == EntityKind::EffectOperation)
    }

    fn lookup_body_path(&self, path: &Path, expected: ExpectedName) -> BodyLookupOutcome {
        let Some(first) = path.segments.first() else {
            return BodyLookupOutcome {
                invalid: Some(ProjectDiagnosticKind::InvalidPath),
                ..BodyLookupOutcome::default()
            };
        };
        let qualified = path.segments.len() > 1;
        let first_requirement = PathRequirement::at(0, path.segments.len(), expected);
        let mut outcome = BodyLookupOutcome::default();
        let mut candidates;
        let mut index;
        match first {
            PathSegment::Super(_) => {
                let mut base = self.module.clone();
                index = 0;
                while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                    let Some(parent) = base.parent() else {
                        outcome.invalid = Some(ProjectDiagnosticKind::PathEscapesRoot);
                        return outcome;
                    };
                    base = parent;
                    index += 1;
                }
                candidates = vec![PathCandidate::Module(base)];
            }
            PathSegment::Identifier(identifier) if qualified && identifier.text == "root" => {
                candidates = vec![PathCandidate::Module(ModuleRef::root(
                    self.module.library(),
                ))];
                index = 1;
            }
            PathSegment::Identifier(identifier) if qualified && identifier.text == "self" => {
                candidates = vec![PathCandidate::Module(self.module.clone())];
                index = 1;
            }
            PathSegment::Identifier(identifier) => {
                let mut names =
                    self.lookup_module_name_for_body(&self.module, &identifier.text, true);
                for namespace in first_requirement.root_namespaces() {
                    let binding = match namespace {
                        Namespace::Type => self.lookup_type_binding(&identifier.text),
                        Namespace::Value => self.lookup_value_binding(&identifier.text),
                        Namespace::Effect => self.lookup_effect_binding(&identifier.text),
                        Namespace::Member => None,
                    };
                    if let Some(binding) = binding {
                        names
                            .candidates
                            .retain(|candidate| candidate.namespace() != *namespace);
                        names
                            .inaccessible
                            .retain(|entity| entity.namespace != *namespace);
                        push_candidate(&mut names.candidates, PathCandidate::Exact(binding));
                    }
                }
                let self_candidate = if identifier.text == "Self"
                    && first_requirement
                        .root_namespaces()
                        .contains(&Namespace::Type)
                {
                    names
                        .candidates
                        .retain(|candidate| candidate.namespace() != Namespace::Type);
                    names
                        .inaccessible
                        .retain(|entity| entity.namespace != Namespace::Type);
                    match &self.self_entity {
                        Some(identity) => {
                            let candidate =
                                if qualified || matches!(expected, ExpectedName::Construct) {
                                    self.self_lookup_candidate(identity)
                                } else {
                                    PathCandidate::Exact(identity.clone())
                                };
                            push_candidate(&mut names.candidates, candidate.clone());
                            Some((
                                candidate,
                                ResolvedSelfReference {
                                    origin: self.origin(identifier.span),
                                    identity: identity.clone(),
                                    target: self.self_target.clone().map(Box::new),
                                },
                            ))
                        }
                        None => {
                            outcome.missing_self_type = true;
                            None
                        }
                    }
                } else {
                    None
                };
                candidates = names
                    .candidates
                    .into_iter()
                    .map(|candidate| self.normalize_type_dependent_candidate(candidate, identifier))
                    .filter(|candidate| {
                        self.candidate_matches_requirement(candidate, first_requirement)
                    })
                    .collect();
                if let Some((candidate, reference)) = self_candidate
                    && candidates.contains(&candidate)
                {
                    outcome.self_reference = Some(reference);
                }
                outcome.inaccessible.extend(
                    names
                        .inaccessible
                        .into_iter()
                        .filter(|entity| first_requirement.accepts_exact(entity)),
                );
                index = 1;
            }
        }

        if index == path.segments.len()
            && matches!(candidates.as_slice(), [PathCandidate::Module(_)])
        {
            candidates.clear();
        }
        while index < path.segments.len() {
            let PathSegment::Identifier(identifier) = &path.segments[index] else {
                outcome.invalid = Some(ProjectDiagnosticKind::InvalidPath);
                return outcome;
            };
            let requirement = PathRequirement::at(index, path.segments.len(), expected);
            let step = self.advance_body_candidates(candidates, identifier, requirement);
            candidates = step.candidates;
            outcome.inaccessible.extend(step.inaccessible);
            if candidates.is_empty() {
                break;
            }
            index += 1;
        }
        outcome.candidates = candidates;
        outcome
    }

    fn lookup_module_name_for_body(
        &self,
        module: &ModuleRef,
        name: &str,
        include_language: bool,
    ) -> BodyLookupOutcome {
        let mut containers = ContainerOutcome::default();
        self.state.lookup_module_name(
            module,
            &self.module,
            name,
            include_language,
            true,
            &mut containers,
        );
        let mut outcome = BodyLookupOutcome::default();
        for container in containers.accessible {
            match container {
                LookupContainer::Module(module) => {
                    push_candidate(&mut outcome.candidates, PathCandidate::Module(module));
                }
                LookupContainer::Entity(entity) if entity.kind == EntityKind::Module => {
                    push_candidate(
                        &mut outcome.candidates,
                        PathCandidate::Module(entity.module),
                    );
                }
                LookupContainer::Entity(entity) => {
                    push_candidate(&mut outcome.candidates, PathCandidate::Exact(entity));
                }
            }
        }
        outcome
            .inaccessible
            .extend(
                containers
                    .inaccessible
                    .into_iter()
                    .filter_map(|container| match container {
                        LookupContainer::Entity(entity) => Some(entity),
                        LookupContainer::Module(module) => module_entity(&module),
                    }),
            );
        outcome
    }

    fn advance_body_candidates(
        &self,
        candidates: Vec<PathCandidate>,
        identifier: &Identifier,
        requirement: PathRequirement,
    ) -> BodyLookupOutcome {
        let mut outcome = BodyLookupOutcome::default();
        for candidate in candidates {
            match candidate {
                PathCandidate::Module(module) => {
                    let names = self.lookup_module_name_for_body(&module, &identifier.text, false);
                    for candidate in names.candidates {
                        let candidate =
                            self.normalize_type_dependent_candidate(candidate, identifier);
                        if self.candidate_matches_requirement(&candidate, requirement) {
                            push_candidate(&mut outcome.candidates, candidate);
                        }
                    }
                    outcome.inaccessible.extend(
                        names
                            .inaccessible
                            .into_iter()
                            .filter(|entity| requirement.accepts_exact(entity)),
                    );
                }
                PathCandidate::Exact(base) => {
                    if base.kind == EntityKind::Module {
                        let names =
                            self.lookup_module_name_for_body(&base.module, &identifier.text, false);
                        for candidate in names.candidates {
                            let candidate =
                                self.normalize_type_dependent_candidate(candidate, identifier);
                            if self.candidate_matches_requirement(&candidate, requirement) {
                                push_candidate(&mut outcome.candidates, candidate);
                            }
                        }
                        outcome.inaccessible.extend(
                            names
                                .inaccessible
                                .into_iter()
                                .filter(|entity| requirement.accepts_exact(entity)),
                        );
                        continue;
                    }
                    let declared_members = self
                        .state
                        .entities
                        .get(&base)
                        .and_then(|entity| entity.members.get(&identifier.text))
                        .cloned()
                        .unwrap_or_default();
                    let mut matching_member_exists = false;
                    for declaration in declared_members {
                        let candidate = match declaration.kind {
                            EntityKind::EnumConstructor => {
                                PathCandidate::Exact(declaration.clone())
                            }
                            EntityKind::Method
                                if matches!(
                                    requirement,
                                    PathRequirement::Terminal(ExpectedName::EffectApplication)
                                ) && matches!(base.kind, EntityKind::Trait) =>
                            {
                                PathCandidate::Exact(declaration.clone())
                            }
                            EntityKind::Method | EntityKind::AssociatedType | EntityKind::Field => {
                                PathCandidate::Selection {
                                    base: base.clone(),
                                    namespace: declaration.namespace,
                                    members: vec![ResolvedSelection {
                                        origin: self.origin(identifier.span),
                                        name: identifier.text.clone(),
                                        declaration: Some(declaration.clone()),
                                    }],
                                }
                            }
                            EntityKind::EffectOperation => continue,
                            _ => continue,
                        };
                        if !self.candidate_matches_requirement(&candidate, requirement) {
                            continue;
                        }
                        matching_member_exists = true;
                        let accessible =
                            self.state.entities.get(&declaration).is_some_and(|entity| {
                                entity.public || self.module.is_descendant_of(&declaration.module)
                            });
                        if accessible {
                            push_candidate(&mut outcome.candidates, candidate);
                        } else {
                            outcome.inaccessible.push(declaration);
                        }
                    }
                    if !matching_member_exists
                        && let Some(namespace) = requirement.pending_namespace()
                        && self.selection_can_be_pending(&base, namespace)
                    {
                        push_candidate(
                            &mut outcome.candidates,
                            PathCandidate::Selection {
                                base,
                                namespace,
                                members: vec![ResolvedSelection {
                                    origin: self.origin(identifier.span),
                                    name: identifier.text.clone(),
                                    declaration: None,
                                }],
                            },
                        );
                    }
                }
                PathCandidate::Selection {
                    base,
                    namespace,
                    mut members,
                } => {
                    if namespace != Namespace::Type {
                        continue;
                    }
                    let Some(namespace) = requirement.pending_namespace() else {
                        continue;
                    };
                    members.push(ResolvedSelection {
                        origin: self.origin(identifier.span),
                        name: identifier.text.clone(),
                        declaration: None,
                    });
                    push_candidate(
                        &mut outcome.candidates,
                        PathCandidate::Selection {
                            base,
                            namespace,
                            members,
                        },
                    );
                }
            }
        }
        outcome
    }

    fn candidate_matches_requirement(
        &self,
        candidate: &PathCandidate,
        requirement: PathRequirement,
    ) -> bool {
        match candidate {
            PathCandidate::Module(_) => matches!(requirement, PathRequirement::Container),
            PathCandidate::Exact(entity) => requirement.accepts_exact(entity),
            PathCandidate::Selection { namespace, .. } => requirement.accepts_selection(*namespace),
        }
    }

    fn selection_can_be_pending(&self, base: &EntityId, namespace: Namespace) -> bool {
        matches!(namespace, Namespace::Type | Namespace::Value)
            && is_selection_base(base)
            && !self.state.closed_member_owners.contains(base)
    }

    fn normalize_type_dependent_candidate(
        &self,
        candidate: PathCandidate,
        identifier: &Identifier,
    ) -> PathCandidate {
        let PathCandidate::Exact(declaration) = &candidate else {
            return candidate;
        };
        if !matches!(
            declaration.kind,
            EntityKind::Method | EntityKind::AssociatedType | EntityKind::Field
        ) {
            return candidate;
        }
        let base = self
            .state
            .entities
            .get(declaration)
            .and_then(|entity| entity.owner.clone())
            .or_else(|| self.self_entity.clone());
        let Some(base) = base else {
            return candidate;
        };
        PathCandidate::Selection {
            base,
            namespace: declaration.namespace,
            members: vec![ResolvedSelection {
                origin: self.origin(identifier.span),
                name: identifier.text.clone(),
                declaration: Some(declaration.clone()),
            }],
        }
    }

    fn lookup_value_binding(&self, name: &str) -> Option<EntityId> {
        self.value_scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
    }

    fn lookup_type_binding(&self, name: &str) -> Option<EntityId> {
        self.type_scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
    }

    fn lookup_effect_binding(&self, name: &str) -> Option<EntityId> {
        self.effect_scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
    }

    fn self_lookup_candidate(&self, identity: &EntityId) -> PathCandidate {
        if let Some(target) = &self.self_target {
            return path_candidate_from_reference(&target.reference);
        }
        self.state
            .entities
            .get(identity)
            .and_then(|entity| entity.owner.clone())
            .map(PathCandidate::Exact)
            .unwrap_or_else(|| PathCandidate::Exact(identity.clone()))
    }

    fn selection_for_reference(
        &self,
        reference: &ResolvedReference,
        name: &str,
        span: Span,
        expected_kind: EntityKind,
    ) -> ResolvedSelection {
        let declaration = match reference {
            ResolvedReference::Exact { target, .. } => self
                .state
                .entities
                .get(target)
                .and_then(|entity| entity.members.get(name))
                .into_iter()
                .flatten()
                .find(|member| member.kind == expected_kind)
                .cloned(),
            ResolvedReference::Selection { .. } => None,
        };
        ResolvedSelection {
            origin: self.origin(span),
            name: name.to_owned(),
            declaration,
        }
    }

    fn associated_type_argument_for_reference(
        &self,
        reference: &ResolvedReference,
        name: &Identifier,
    ) -> Result<ResolvedSelection, ProjectDiagnostic> {
        let selection = self.selection_for_reference(
            reference,
            &name.text,
            name.span,
            EntityKind::AssociatedType,
        );
        let missing_without_pending_boundary =
            reference_exact_target(reference).is_some_and(|target| {
                selection.declaration.is_none()
                    && !self.selection_can_be_pending(target, Namespace::Type)
            });
        if missing_without_pending_boundary {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Type,
                    name: name.text.clone(),
                },
                self.origin(name.span),
            ));
        }
        Ok(selection)
    }

    fn required_member_for_reference(
        &self,
        reference: &ResolvedReference,
        name: &Identifier,
        expected_kind: EntityKind,
    ) -> Result<ResolvedSelection, ProjectDiagnostic> {
        let selection =
            self.selection_for_reference(reference, &name.text, name.span, expected_kind);
        if selection.declaration.is_none() {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Value,
                    name: name.text.clone(),
                },
                self.origin(name.span),
            ));
        }
        Ok(selection)
    }

    fn resolve_effect_operation(
        &self,
        effect: &ResolvedReference,
        operation: &Identifier,
    ) -> Result<ResolvedSelection, ProjectDiagnostic> {
        let exact_effect = reference_exact_target(effect).is_some_and(|target| {
            matches!(target.kind, EntityKind::Effect | EntityKind::LanguageEffect)
        });
        let selection = self.selection_for_reference(
            effect,
            &operation.text,
            operation.span,
            EntityKind::EffectOperation,
        );
        if !exact_effect || selection.declaration.is_none() {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Value,
                    name: operation.text.clone(),
                },
                self.origin(operation.span),
            ));
        }
        Ok(selection)
    }

    fn resolve_block(&mut self, block: &Block) -> Result<ResolvedBlock, ProjectDiagnostic> {
        self.value_scopes.push(BTreeMap::new());
        let mut statements = Vec::new();
        for statement in &block.statements {
            statements.push(self.resolve_statement(statement)?);
        }
        let tail = block
            .tail
            .as_ref()
            .map(|tail| self.resolve_expr(tail).map(Box::new))
            .transpose()?;
        self.value_scopes.pop();
        Ok(ResolvedBlock {
            span: block.span,
            statements,
            tail,
        })
    }

    fn resolve_block_with_bindings(
        &mut self,
        block: &Block,
        bindings: BTreeMap<String, EntityId>,
    ) -> Result<ResolvedBlock, ProjectDiagnostic> {
        self.value_scopes.push(bindings);
        let resolved = self.resolve_block(block)?;
        self.value_scopes.pop();
        Ok(resolved)
    }

    fn resolve_statement(
        &mut self,
        statement: &Statement,
    ) -> Result<ResolvedStatement, ProjectDiagnostic> {
        let kind = match &statement.kind {
            StatementKind::Let { binding, value } => match binding {
                LetBinding::Name {
                    name,
                    mutable,
                    annotation,
                } => {
                    let annotation = annotation
                        .as_ref()
                        .map(|annotation| self.resolve_type(annotation))
                        .transpose()?;
                    let value = self.resolve_expr(value)?;
                    let binding = self.make_value_binding(
                        name,
                        name.span,
                        EntityKind::Local,
                        self.owner.clone(),
                    );
                    self.value_scopes
                        .last_mut()
                        .expect("let appears in a block scope")
                        .insert(name.text.clone(), binding.identity.clone());
                    ResolvedStatementKind::Let {
                        bindings: vec![binding],
                        mutable: *mutable,
                        annotation,
                        value,
                    }
                }
                LetBinding::Tuple(pattern) => {
                    let (pattern, bindings) = self.resolve_single_pattern(pattern)?;
                    let value = self.resolve_expr(value)?;
                    let resolved_bindings = bindings
                        .iter()
                        .map(|(name, identity)| ResolvedBinding {
                            origin: pattern_binding_origin(&pattern, name)
                                .unwrap_or_else(|| self.origin(pattern.span)),
                            identity: identity.clone(),
                        })
                        .collect::<Vec<_>>();
                    self.value_scopes
                        .last_mut()
                        .expect("let appears in a block scope")
                        .extend(bindings);
                    ResolvedStatementKind::Let {
                        bindings: resolved_bindings,
                        mutable: None,
                        annotation: None,
                        value,
                    }
                }
            },
            StatementKind::Return(value) => ResolvedStatementKind::Return(
                value
                    .as_ref()
                    .map(|value| self.resolve_expr(value))
                    .transpose()?,
            ),
            StatementKind::Break => ResolvedStatementKind::Break,
            StatementKind::Continue => ResolvedStatementKind::Continue,
            StatementKind::Assignment {
                target,
                operator,
                value,
            } => ResolvedStatementKind::Assignment {
                target: self.resolve_place(target)?,
                operator: (operator.span, operator.kind),
                value: self.resolve_expr(value)?,
            },
            StatementKind::Expression(expression) => {
                ResolvedStatementKind::Expression(self.resolve_expr(expression)?)
            }
            StatementKind::IfLet {
                pattern,
                value,
                then_branch,
                else_branch,
            } => {
                let (pattern, bindings) = self.resolve_single_pattern(pattern)?;
                let value = self.resolve_expr(value)?;
                let then_branch = self.resolve_block_with_bindings(then_branch, bindings)?;
                let else_branch = else_branch
                    .as_ref()
                    .map(|branch| self.resolve_block(branch))
                    .transpose()?;
                ResolvedStatementKind::IfLet {
                    pattern,
                    value,
                    then_branch,
                    else_branch,
                }
            }
            StatementKind::While { condition, body } => ResolvedStatementKind::While {
                condition: self.resolve_expr(condition)?,
                body: self.resolve_block(body)?,
            },
            StatementKind::For {
                binding,
                iterable,
                body,
            } => {
                let mut bindings = BTreeMap::new();
                let names = match binding {
                    ForBinding::Name(name) => vec![name],
                    ForBinding::Tuple { names, .. } => names.iter().collect(),
                };
                let mut resolved_bindings = Vec::new();
                for name in names {
                    let resolved = self.make_value_binding(
                        name,
                        name.span,
                        EntityKind::Local,
                        self.owner.clone(),
                    );
                    if let Some(previous) =
                        bindings.insert(name.text.clone(), resolved.identity.clone())
                    {
                        return Err(ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::DuplicateBinding {
                                name: name.text.clone(),
                            },
                            primary: Some(self.origin(name.span)),
                            related: entity_origin(&previous).into_iter().collect(),
                        });
                    }
                    resolved_bindings.push(resolved);
                }
                let iterable = self.resolve_expr(iterable)?;
                let body = self.resolve_block_with_bindings(body, bindings)?;
                ResolvedStatementKind::For {
                    bindings: resolved_bindings,
                    iterable,
                    body,
                }
            }
            StatementKind::Loop(body) => ResolvedStatementKind::Loop(self.resolve_block(body)?),
        };
        Ok(ResolvedStatement {
            span: statement.span,
            kind,
            terminator: statement.terminator.clone(),
        })
    }

    fn resolve_place(&self, place: &PlaceExpr) -> Result<ResolvedPlace, ProjectDiagnostic> {
        let path = single_identifier_path(&place.root);
        Ok(ResolvedPlace {
            span: place.span,
            root: self.resolve_path(&path, ExpectedName::Value)?,
            fields: place
                .fields
                .iter()
                .map(|field| ResolvedSelection {
                    origin: self.origin(field.span),
                    name: field.text.clone(),
                    declaration: None,
                })
                .collect(),
        })
    }

    fn resolve_expr(&mut self, expression: &Expr) -> Result<ResolvedExpr, ProjectDiagnostic> {
        let kind = match &expression.kind {
            ExprKind::Integer(value) => ResolvedExprKind::Integer(value.clone()),
            ExprKind::Float(value) => ResolvedExprKind::Float(value.clone()),
            ExprKind::String(value) => ResolvedExprKind::String(value.clone()),
            ExprKind::RawString { value, delimiter } => ResolvedExprKind::RawString {
                value: value.clone(),
                delimiter: *delimiter,
            },
            ExprKind::InterpolatedString(parts) => ResolvedExprKind::InterpolatedString(
                parts
                    .iter()
                    .map(|part| match part {
                        InterpolationPart::String(value) => Ok(ResolvedInterpolationPart::String {
                            origin: self.origin(value.span),
                            value: value.value.clone(),
                        }),
                        InterpolationPart::Expression(expression) => {
                            Ok(ResolvedInterpolationPart::Expression(Box::new(
                                self.resolve_expr(expression)?,
                            )))
                        }
                    })
                    .collect::<Result<Vec<_>, ProjectDiagnostic>>()?,
            ),
            ExprKind::Boolean(value) => ResolvedExprKind::Boolean(*value),
            ExprKind::Path(path) => {
                ResolvedExprKind::Path(self.resolve_path(path, ExpectedName::Value)?)
            }
            ExprKind::NamedConstruct { path, entries } => {
                let target = self.resolve_path(path, ExpectedName::Construct)?;
                let mut resolved_entries = Vec::new();
                for entry in entries {
                    resolved_entries.push(match &entry.kind {
                        ConstructEntryKind::Spread(expression) => {
                            ResolvedConstructEntry::Spread(self.resolve_expr(expression)?)
                        }
                        ConstructEntryKind::Field { name, value } => {
                            let member = self.required_member_for_reference(
                                &target,
                                name,
                                EntityKind::Field,
                            )?;
                            let shorthand = if value.is_none() {
                                Some(Box::new(self.resolve_path(
                                    &single_identifier_path(name),
                                    ExpectedName::Value,
                                )?))
                            } else {
                                None
                            };
                            ResolvedConstructEntry::Field {
                                member,
                                value: value
                                    .as_ref()
                                    .map(|value| self.resolve_expr(value).map(Box::new))
                                    .transpose()?,
                                shorthand,
                            }
                        }
                    });
                }
                ResolvedExprKind::NamedConstruct {
                    target,
                    entries: resolved_entries,
                }
            }
            ExprKind::List(elements) => ResolvedExprKind::List(
                elements
                    .iter()
                    .map(|element| self.resolve_expr(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            ExprKind::Unit => ResolvedExprKind::Unit,
            ExprKind::Parenthesized(inner) => {
                ResolvedExprKind::Parenthesized(Box::new(self.resolve_expr(inner)?))
            }
            ExprKind::Tuple(elements) => ResolvedExprKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_expr(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            ExprKind::Block(block) => ResolvedExprKind::Block(self.resolve_block(block)?),
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => ResolvedExprKind::If {
                condition: Box::new(self.resolve_expr(condition)?),
                then_branch: self.resolve_block(then_branch)?,
                else_branch: else_branch
                    .as_ref()
                    .map(|branch| self.resolve_expr(branch).map(Box::new))
                    .transpose()?,
            },
            ExprKind::Match { scrutinee, arms } => ResolvedExprKind::Match {
                scrutinee: Box::new(self.resolve_expr(scrutinee)?),
                arms: arms
                    .iter()
                    .map(|arm| self.resolve_match_arm(arm))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Handle { body, handlers } => ResolvedExprKind::Handle {
                body: self.resolve_block(body)?,
                handlers: handlers
                    .iter()
                    .map(|handler| self.resolve_handler(handler))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Closure(closure) => {
                ResolvedExprKind::Closure(self.resolve_closure(expression.span, closure)?)
            }
            ExprKind::Unsafe(block) => ResolvedExprKind::Unsafe(self.resolve_block(block)?),
            ExprKind::Catch { expression, arms } => ResolvedExprKind::Catch {
                expression: Box::new(self.resolve_expr(expression)?),
                arms: arms
                    .iter()
                    .map(|arm| self.resolve_match_arm(arm))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Unary { operator, operand } => ResolvedExprKind::Unary {
                operator: (operator.span, operator.kind),
                operand: Box::new(self.resolve_expr(operand)?),
            },
            ExprKind::Binary {
                left,
                operator,
                right,
            } => ResolvedExprKind::Binary {
                left: Box::new(self.resolve_expr(left)?),
                operator: (operator.span, operator.kind),
                right: Box::new(self.resolve_expr(right)?),
            },
            ExprKind::Propagate(inner) => {
                ResolvedExprKind::Propagate(Box::new(self.resolve_expr(inner)?))
            }
            ExprKind::Call { callee, arguments } => ResolvedExprKind::Call {
                callee: Box::new(self.resolve_expr(callee)?),
                arguments: arguments
                    .iter()
                    .map(|argument| self.resolve_call_argument(argument))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Index { receiver, index } => ResolvedExprKind::Index {
                receiver: Box::new(self.resolve_expr(receiver)?),
                index: Box::new(self.resolve_expr(index)?),
            },
            ExprKind::TupleField { receiver, index } => ResolvedExprKind::TupleField {
                receiver: Box::new(self.resolve_expr(receiver)?),
                index: index.value.clone(),
                origin: self.origin(index.span),
            },
            ExprKind::Field { receiver, name } => ResolvedExprKind::Field {
                receiver: Box::new(self.resolve_expr(receiver)?),
                field: ResolvedSelection {
                    origin: self.origin(name.span),
                    name: name.text.clone(),
                    declaration: None,
                },
            },
            ExprKind::MethodCall {
                receiver,
                method,
                arguments,
            } => {
                let receiver = if let ExprKind::Path(path) = &receiver.kind {
                    ResolvedExpr {
                        span: receiver.span,
                        kind: ResolvedExprKind::Path(
                            self.resolve_method_receiver_path(path, method)?,
                        ),
                    }
                } else {
                    self.resolve_expr(receiver)?
                };
                let method = match &receiver.kind {
                    ResolvedExprKind::Path(reference)
                        if reference_exact_target(reference)
                            .is_some_and(|target| target.namespace == Namespace::Effect) =>
                    {
                        self.resolve_effect_operation(reference, method)?
                    }
                    _ => ResolvedSelection {
                        origin: self.origin(method.span),
                        name: method.text.clone(),
                        declaration: None,
                    },
                };
                ResolvedExprKind::MethodCall {
                    receiver: Box::new(receiver),
                    method,
                    arguments: arguments
                        .iter()
                        .map(|argument| self.resolve_call_argument(argument))
                        .collect::<Result<Vec<_>, _>>()?,
                }
            }
        };
        Ok(ResolvedExpr {
            span: expression.span,
            kind,
        })
    }

    fn resolve_call_argument(
        &mut self,
        argument: &CallArgument,
    ) -> Result<ResolvedCallArgument, ProjectDiagnostic> {
        Ok(match argument {
            CallArgument::Expression(expression) => {
                ResolvedCallArgument::Expression(self.resolve_expr(expression)?)
            }
            CallArgument::Mode { span, mode, place } => ResolvedCallArgument::Mode {
                span: *span,
                mode: (mode.span, mode.kind),
                place: self.resolve_place(place)?,
            },
        })
    }

    fn resolve_match_arm(&mut self, arm: &MatchArm) -> Result<ResolvedMatchArm, ProjectDiagnostic> {
        let (pattern, bindings) = self.resolve_or_pattern(&arm.pattern)?;
        self.value_scopes.push(bindings);
        let guard = arm
            .guard
            .as_ref()
            .map(|guard| self.resolve_expr(guard))
            .transpose()?;
        let body = self.resolve_expr(&arm.body)?;
        self.value_scopes.pop();
        Ok(ResolvedMatchArm {
            span: arm.span,
            pattern,
            guard,
            body,
        })
    }

    fn resolve_handler(&mut self, handler: &Handler) -> Result<ResolvedHandler, ProjectDiagnostic> {
        let effect = self.resolve_path(&handler.effect, ExpectedName::Effect)?;
        let operation = self.resolve_effect_operation(&effect, &handler.operation)?;
        let owner = OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span: handler.span,
            kind: EntityKind::Handler,
            name: handler.operation.text.clone(),
        };
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (parameters, bindings) = self.resolve_parameters(&handler.parameters, owner)?;
        self.value_scopes.push(bindings);
        let body = self.resolve_expr(&handler.body)?;
        self.value_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedHandler {
            span: handler.span,
            effect,
            operation,
            parameters,
            body,
        })
    }

    fn resolve_closure(
        &mut self,
        span: Span,
        closure: &ClosureExpression,
    ) -> Result<ResolvedClosure, ProjectDiagnostic> {
        let mut seen_captures = BTreeMap::<String, OriginRef>::new();
        let mut captures = Vec::new();
        if let Some(list) = &closure.captures {
            for capture in &list.captures {
                let origin = self.origin(capture.name.span);
                if let Some(previous) =
                    seen_captures.insert(capture.name.text.clone(), origin.clone())
                {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::DuplicateBinding {
                            name: capture.name.text.clone(),
                        },
                        primary: Some(origin),
                        related: vec![previous],
                    });
                }
                captures.push(ResolvedCapture {
                    span: capture.span,
                    mode: capture.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                    reference: self.resolve_path(
                        &single_identifier_path(&capture.name),
                        ExpectedName::Value,
                    )?,
                    annotation: capture
                        .annotation
                        .as_ref()
                        .map(|annotation| self.resolve_type(annotation))
                        .transpose()?,
                });
            }
        }
        let owner = OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span,
            kind: EntityKind::Closure,
            name: "closure".to_owned(),
        };
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (parameters, bindings) = self.resolve_parameters(&closure.parameters, owner)?;
        let return_type = closure
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_return_annotation(return_type).map(Box::new))
            .transpose()?;
        let effects = closure
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.value_scopes.push(bindings);
        let body = self.resolve_block(&closure.body)?;
        self.value_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedClosure {
            captures,
            parameters,
            return_type,
            effects,
            body,
        })
    }

    fn resolve_single_pattern(
        &mut self,
        pattern: &Pattern,
    ) -> Result<(ResolvedPattern, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut bindings = BTreeMap::new();
        let mut seen = BTreeSet::new();
        let resolved =
            self.resolve_pattern(pattern, pattern.span, None, &mut bindings, &mut seen)?;
        Ok((resolved, bindings))
    }

    fn resolve_or_pattern(
        &mut self,
        pattern: &OrPattern,
    ) -> Result<(ResolvedPattern, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut alternatives = Vec::new();
        let mut canonical = BTreeMap::new();
        for (index, alternative) in pattern.alternatives.iter().enumerate() {
            let mut bindings = BTreeMap::new();
            let mut seen = BTreeSet::new();
            alternatives.push(self.resolve_pattern(
                alternative,
                pattern.span,
                (index != 0).then_some(&canonical),
                &mut bindings,
                &mut seen,
            )?);
            if index == 0 {
                canonical = bindings;
            } else if bindings.keys().collect::<Vec<_>>() != canonical.keys().collect::<Vec<_>>() {
                return Err(self.diagnostic(
                    ProjectDiagnosticKind::PatternBindingMismatch,
                    self.origin(pattern.span),
                ));
            }
        }
        let kind = if alternatives.len() == 1 {
            alternatives
                .pop()
                .expect("or-pattern has one alternative")
                .kind
        } else {
            ResolvedPatternKind::Or(alternatives)
        };
        Ok((
            ResolvedPattern {
                span: pattern.span,
                kind,
            },
            canonical,
        ))
    }

    fn resolve_pattern(
        &mut self,
        pattern: &Pattern,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedPattern, ProjectDiagnostic> {
        let kind = match &pattern.kind {
            PatternKind::Wildcard => ResolvedPatternKind::Wildcard,
            PatternKind::Integer(value) => ResolvedPatternKind::Integer(value.clone()),
            PatternKind::Float(value) => ResolvedPatternKind::Float(value.clone()),
            PatternKind::String(value) => ResolvedPatternKind::String(value.clone()),
            PatternKind::Boolean(value) => ResolvedPatternKind::Boolean(*value),
            PatternKind::Tuple(elements) => ResolvedPatternKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_pattern(element, anchor, expected, bindings, seen))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            PatternKind::QualifiedBinding(qualified) => {
                ResolvedPatternKind::Binding(ResolvedPatternBinding {
                    binding: self.pattern_binding(
                        &qualified.name,
                        anchor,
                        expected,
                        bindings,
                        seen,
                    )?,
                    qualifier: Some((qualified.mode.span, qualified.mode.kind)),
                })
            }
            PatternKind::Path { path, fields }
                if fields.is_none()
                    && path.segments.len() == 1
                    && matches!(path.segments.first(), Some(PathSegment::Identifier(_))) =>
            {
                let identifier = match path.segments.first().expect("one path segment") {
                    PathSegment::Identifier(identifier) => identifier,
                    PathSegment::Super(_) => unreachable!(),
                };
                if let Some(target) = self.unit_constructor(path)? {
                    ResolvedPatternKind::Constructor {
                        target: ResolvedReference::Exact {
                            occurrence: self.origin(path.span),
                            target,
                            self_reference: None,
                        },
                        fields: None,
                    }
                } else {
                    ResolvedPatternKind::Binding(ResolvedPatternBinding {
                        binding: self
                            .pattern_binding(identifier, anchor, expected, bindings, seen)?,
                        qualifier: None,
                    })
                }
            }
            PatternKind::Path { path, fields } => {
                let target = self.resolve_path(path, ExpectedName::PatternConstructor)?;
                let fields = fields
                    .as_ref()
                    .map(|fields| {
                        self.resolve_pattern_fields(
                            fields, &target, anchor, expected, bindings, seen,
                        )
                    })
                    .transpose()?;
                ResolvedPatternKind::Constructor { target, fields }
            }
        };
        Ok(ResolvedPattern {
            span: pattern.span,
            kind,
        })
    }

    fn resolve_pattern_fields(
        &mut self,
        fields: &PatternFields,
        target: &ResolvedReference,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedPatternFields, ProjectDiagnostic> {
        Ok(match fields {
            PatternFields::Positional(patterns) => ResolvedPatternFields::Positional(
                patterns
                    .iter()
                    .map(|pattern| self.resolve_pattern(pattern, anchor, expected, bindings, seen))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            PatternFields::Named { fields, rest } => {
                let mut resolved = Vec::new();
                for field in fields {
                    let member =
                        self.required_member_for_reference(target, &field.name, EntityKind::Field)?;
                    let pattern = if let Some(pattern) = &field.pattern {
                        self.resolve_pattern(pattern, anchor, expected, bindings, seen)?
                    } else {
                        ResolvedPattern {
                            span: field.name.span,
                            kind: ResolvedPatternKind::Binding(ResolvedPatternBinding {
                                binding: self.pattern_binding(
                                    &field.name,
                                    anchor,
                                    expected,
                                    bindings,
                                    seen,
                                )?,
                                qualifier: None,
                            }),
                        }
                    };
                    resolved.push(ResolvedNamedPatternField { member, pattern });
                }
                ResolvedPatternFields::Named {
                    fields: resolved,
                    rest: *rest,
                }
            }
        })
    }

    fn pattern_binding(
        &mut self,
        identifier: &Identifier,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedBinding, ProjectDiagnostic> {
        if !seen.insert(identifier.text.clone()) {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::DuplicateBinding {
                    name: identifier.text.clone(),
                },
                self.origin(identifier.span),
            ));
        }
        let identity = expected
            .and_then(|expected| expected.get(&identifier.text).cloned())
            .unwrap_or_else(|| {
                source_id(
                    &self.module,
                    &self.source,
                    anchor,
                    Namespace::Value,
                    EntityKind::PatternBinding,
                    &identifier.text,
                    Some(self.owner.clone()),
                )
            });
        bindings.insert(identifier.text.clone(), identity.clone());
        self.insert_scoped_entity(identity.clone());
        Ok(ResolvedBinding {
            origin: self.origin(identifier.span),
            identity,
        })
    }

    fn unit_constructor(&self, path: &Path) -> Result<Option<EntityId>, ProjectDiagnostic> {
        let outcome = self.lookup_body_path(path, ExpectedName::Value);
        if let Some(kind) = outcome.invalid {
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        let mut units =
            outcome
                .candidates
                .into_iter()
                .filter_map(|candidate| match candidate {
                    PathCandidate::Exact(entity)
                        if self.state.entities.get(&entity).is_some_and(|metadata| {
                            metadata.shape == EntityShape::ConstructorUnit
                        }) =>
                    {
                        Some(entity)
                    }
                    _ => None,
                })
                .collect::<Vec<_>>();
        units.sort();
        units.dedup();
        if units.len() > 1 {
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::AmbiguousName {
                    name: path_text(path),
                },
                primary: Some(self.origin(path.span)),
                related: units.iter().filter_map(entity_origin).collect(),
            });
        }
        Ok(units.pop())
    }

    fn make_value_binding(
        &mut self,
        identifier: &Identifier,
        site: Span,
        kind: EntityKind,
        owner: OwnerKey,
    ) -> ResolvedBinding {
        let identity = source_id(
            &self.module,
            &self.source,
            site,
            Namespace::Value,
            kind,
            &identifier.text,
            Some(owner),
        );
        self.insert_scoped_entity(identity.clone());
        ResolvedBinding {
            origin: self.origin(identifier.span),
            identity,
        }
    }
}

fn single_identifier_path(identifier: &Identifier) -> Path {
    Path {
        span: identifier.span,
        segments: vec![PathSegment::Identifier(identifier.clone())],
    }
}

fn pattern_binding_origin(pattern: &ResolvedPattern, name: &str) -> Option<OriginRef> {
    match &pattern.kind {
        ResolvedPatternKind::Binding(binding) if binding.binding.identity.name == name => {
            Some(binding.binding.origin.clone())
        }
        ResolvedPatternKind::Tuple(patterns) | ResolvedPatternKind::Or(patterns) => patterns
            .iter()
            .find_map(|pattern| pattern_binding_origin(pattern, name)),
        ResolvedPatternKind::Constructor {
            fields: Some(fields),
            ..
        } => match fields {
            ResolvedPatternFields::Positional(patterns) => patterns
                .iter()
                .find_map(|pattern| pattern_binding_origin(pattern, name)),
            ResolvedPatternFields::Named { fields, .. } => fields
                .iter()
                .find_map(|field| pattern_binding_origin(&field.pattern, name)),
        },
        ResolvedPatternKind::Wildcard
        | ResolvedPatternKind::Integer(_)
        | ResolvedPatternKind::Float(_)
        | ResolvedPatternKind::String(_)
        | ResolvedPatternKind::Boolean(_)
        | ResolvedPatternKind::Binding(_)
        | ResolvedPatternKind::Constructor { fields: None, .. } => None,
    }
}

fn reference_exact_target(reference: &ResolvedReference) -> Option<&EntityId> {
    match reference {
        ResolvedReference::Exact { target, .. } => Some(target),
        ResolvedReference::Selection { .. } => None,
    }
}

fn is_selection_base(entity: &EntityId) -> bool {
    matches!(
        entity.kind,
        EntityKind::Struct
            | EntityKind::Enum
            | EntityKind::TypeAlias
            | EntityKind::ExternType
            | EntityKind::Trait
            | EntityKind::TypeParameter
            | EntityKind::SelfType
            | EntityKind::AssociatedType
            | EntityKind::LanguageType
    )
}

fn push_candidate(candidates: &mut Vec<PathCandidate>, candidate: PathCandidate) {
    if !candidates.contains(&candidate) {
        candidates.push(candidate);
    }
}

fn deduplicate_candidates(candidates: &mut Vec<PathCandidate>) {
    let mut unique = Vec::new();
    for candidate in candidates.drain(..) {
        push_candidate(&mut unique, candidate);
    }
    *candidates = unique;
}

#[derive(Default)]
struct LookupOutcome {
    accessible: BTreeSet<EntityId>,
    inaccessible: BTreeSet<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
}

impl LookupOutcome {
    fn invalid(kind: ProjectDiagnosticKind) -> Self {
        Self {
            invalid: Some(kind),
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum LookupContainer {
    Module(ModuleRef),
    Entity(EntityId),
}

#[derive(Default)]
struct ContainerOutcome {
    accessible: BTreeSet<LookupContainer>,
    inaccessible: BTreeSet<LookupContainer>,
    escaped_root: bool,
}

impl ContainerOutcome {
    fn module(module: ModuleRef) -> Self {
        Self {
            accessible: BTreeSet::from([LookupContainer::Module(module)]),
            ..Self::default()
        }
    }

    fn escaped() -> Self {
        Self {
            escaped_root: true,
            ..Self::default()
        }
    }

    fn retain_containers(&mut self, entities: &BTreeMap<EntityId, Entity>) {
        self.accessible
            .retain(|container| is_lookup_container(container, entities));
        self.inaccessible
            .retain(|container| is_lookup_container(container, entities));
    }
}

fn is_lookup_container(container: &LookupContainer, entities: &BTreeMap<EntityId, Entity>) -> bool {
    match container {
        LookupContainer::Module(_) => true,
        LookupContainer::Entity(id) => {
            id.kind == EntityKind::Module
                || entities
                    .get(id)
                    .is_some_and(|entity| !entity.members.is_empty())
        }
    }
}

fn flatten_imports(
    module: &ModuleRef,
    source: &SourceRef,
    declarations: &[UseDeclaration],
) -> Vec<ImportDirective> {
    let mut directives = Vec::new();
    for declaration in declarations {
        let public = declaration.visibility.is_some();
        match &declaration.suffix {
            Some(UseSuffix::Items { items, .. }) => {
                for item in items {
                    let mut path = declaration.path.clone();
                    path.span.end = item.name.span.end;
                    path.segments
                        .push(PathSegment::Identifier(item.name.clone()));
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            library: module.library(),
                            source: source.clone(),
                            span: item.span,
                        },
                        public,
                        path,
                        local_name: item.alias.as_ref().unwrap_or(&item.name).text.clone(),
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: None,
                    });
                }
            }
            Some(UseSuffix::Alias(alias)) => directives.push(ImportDirective {
                module: module.clone(),
                origin: OriginRef {
                    library: module.library(),
                    source: source.clone(),
                    span: declaration.span,
                },
                public,
                path: declaration.path.clone(),
                local_name: alias.text.clone(),
                candidates: BTreeSet::new(),
                inaccessible: BTreeSet::new(),
                invalid: None,
            }),
            None => {
                if let Some(local_name) = path_terminal_name(&declaration.path) {
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            library: module.library(),
                            source: source.clone(),
                            span: declaration.span,
                        },
                        public,
                        path: declaration.path.clone(),
                        local_name,
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: None,
                    });
                } else {
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            library: module.library(),
                            source: source.clone(),
                            span: declaration.span,
                        },
                        public,
                        path: declaration.path.clone(),
                        local_name: "super".to_owned(),
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: Some(ProjectDiagnosticKind::InvalidPath),
                    });
                }
            }
        }
    }
    directives
}

fn declaration_entity(
    module: &ModuleRef,
    source: &SourceRef,
    declaration: &Declaration,
) -> Option<(EntityId, bool)> {
    let (name, namespace, kind, public) = match &declaration.kind {
        DeclarationKind::Function(declared) => (
            &declared.item.name,
            Namespace::Value,
            EntityKind::Function,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Struct(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Struct,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Enum(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Enum,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Trait(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Trait,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Effect(declared) => (
            &declared.item.name,
            Namespace::Effect,
            EntityKind::Effect,
            declared.visibility.is_some(),
        ),
        DeclarationKind::EffectAlias(declared) => (
            &declared.item.name,
            Namespace::Effect,
            EntityKind::EffectAlias,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Extern(declared) => match &declared.item {
            ExternDeclaration::Function(function) => (
                &function.name,
                Namespace::Value,
                EntityKind::ExternFunction,
                declared.visibility.is_some(),
            ),
            ExternDeclaration::Type { name, .. } => (
                name,
                Namespace::Type,
                EntityKind::ExternType,
                declared.visibility.is_some(),
            ),
        },
        DeclarationKind::TypeAlias(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::TypeAlias,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Const(declared) => (
            &declared.item.name,
            Namespace::Value,
            EntityKind::Const,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Module(declared) => {
            return Some((
                module_id(&module.child(&declared.item.name.text)),
                declared.visibility.is_some(),
            ));
        }
        DeclarationKind::InherentImpl(_) | DeclarationKind::TraitImpl(_) => return None,
    };
    Some((
        source_id(module, source, name.span, namespace, kind, &name.text, None),
        public,
    ))
}

fn add_delivery(table: &mut BindingTable, delivery: Delivery, namespace: Namespace, name: String) {
    table
        .entry((namespace, name))
        .or_default()
        .entry(delivery.target.clone())
        .and_modify(|existing| existing.public |= delivery.public)
        .or_insert(delivery);
}

fn module_id(module: &ModuleRef) -> EntityId {
    EntityId {
        module: module.clone(),
        namespace: Namespace::Type,
        kind: EntityKind::Module,
        name: module
            .path()
            .last()
            .cloned()
            .unwrap_or_else(|| "<root>".to_owned()),
        site: EntitySite::Module(module.clone()),
        owner: None,
    }
}

fn module_entity(module: &ModuleRef) -> Option<EntityId> {
    module.source_library().map(|_| module_id(module))
}

fn language_id(
    namespace: Namespace,
    kind: EntityKind,
    name: &str,
    owner: Option<OwnerKey>,
) -> EntityId {
    EntityId {
        module: ModuleRef::language_root(),
        namespace,
        kind,
        name: name.to_owned(),
        site: EntitySite::Language,
        owner,
    }
}

fn source_id(
    module: &ModuleRef,
    source: &SourceRef,
    span: Span,
    namespace: Namespace,
    kind: EntityKind,
    name: &str,
    owner: Option<OwnerKey>,
) -> EntityId {
    EntityId {
        module: module.clone(),
        namespace,
        kind,
        name: name.to_owned(),
        site: EntitySite::Source(OriginRef {
            library: module.library(),
            source: source.clone(),
            span,
        }),
        owner,
    }
}

fn impl_id(module: &ModuleRef, source: &SourceRef, span: Span, kind: EntityKind) -> EntityId {
    source_id(module, source, span, Namespace::Member, kind, "impl", None)
}

fn owner_key_from_entity(entity: &EntityId) -> OwnerKey {
    let (source, span) = match &entity.site {
        EntitySite::Source(origin) => (origin.source.clone(), origin.span),
        EntitySite::Language => (SourceRef::Root, Span::new(0, 0)),
        EntitySite::Module(module) => (
            SourceRef::Root,
            Span::new(module.path().len(), module.path().len()),
        ),
    };
    OwnerKey {
        module: entity.module.clone(),
        source,
        span,
        kind: entity.kind,
        name: entity.name.clone(),
    }
}

fn owner_site_span(entity: &EntityId) -> Span {
    match &entity.site {
        EntitySite::Source(origin) => origin.span,
        EntitySite::Language | EntitySite::Module(_) => Span::new(0, 0),
    }
}

fn owner_public(state: &ResolverState, owner: &EntityId) -> bool {
    state
        .entities
        .get(owner)
        .is_some_and(|entity| entity.public)
}

fn core_role_bindings(roles: &CoreRoles) -> BTreeMap<String, EntityId> {
    [
        ("Option", &roles.option.declaration),
        ("Ordering", &roles.ordering.declaration),
        ("PartialEq", &roles.partial_eq.declaration),
        ("Eq", &roles.eq),
        ("PartialOrd", &roles.partial_ord.declaration),
        ("Ord", &roles.ord.declaration),
        ("Clone", &roles.clone.declaration),
        ("Copy", &roles.copy),
        ("Drop", &roles.drop.declaration),
        ("Display", &roles.display.declaration),
        ("Debug", &roles.debug.declaration),
        ("Hash", &roles.hash.declaration),
        ("FnOnce", &roles.fn_once),
        ("FnMut", &roles.fn_mut),
        ("Fn", &roles.function),
        ("Iterator", &roles.iterator.declaration),
        ("Iterable", &roles.iterable.declaration),
    ]
    .into_iter()
    .map(|(name, identity)| (name.to_owned(), identity.clone()))
    .collect()
}

fn is_exact_core_binding(core: LibraryId, name: &str, target: &EntityId) -> bool {
    (CORE_ENUMS.contains(&name) || CORE_TRAITS.contains(&name))
        && target.name == name
        && target.namespace == Namespace::Type
        && target.owner.is_none()
        && target.module == ModuleRef::root(core)
        && matches!(
            &target.site,
            EntitySite::Source(OriginRef {
                library,
                source: SourceRef::Root,
                ..
            }) if *library == core
        )
}

fn is_protected_name(namespace: Namespace, name: &str) -> bool {
    match namespace {
        Namespace::Type => {
            LANGUAGE_TYPES.contains(&name)
                || CORE_ENUMS.contains(&name)
                || CORE_TRAITS.contains(&name)
        }
        Namespace::Effect => LANGUAGE_EFFECTS.contains(&name),
        Namespace::Value | Namespace::Member => false,
    }
}

fn type_declaration_name_diagnostic(entity: &EntityId) -> Option<ProjectDiagnostic> {
    if entity.module.is_language() || entity.namespace != Namespace::Type {
        return None;
    }
    let kind = if entity.name == "Self" {
        ProjectDiagnosticKind::InvalidSelf {
            library: entity.module.library(),
        }
    } else if is_protected_name(Namespace::Type, &entity.name) {
        ProjectDiagnosticKind::ReservedLanguageBinding {
            library: entity.module.library(),
            namespace: NameNamespace::Type,
            name: entity.name.clone(),
        }
    } else {
        return None;
    };
    Some(ProjectDiagnostic {
        kind,
        primary: entity_origin(entity),
        related: Vec::new(),
    })
}

fn path_text(path: &Path) -> String {
    path.segments
        .iter()
        .map(|segment| match segment {
            PathSegment::Identifier(identifier) => identifier.text.as_str(),
            PathSegment::Super(_) => "super",
        })
        .collect::<Vec<_>>()
        .join("::")
}

fn path_segment_span(segment: &PathSegment) -> Span {
    match segment {
        PathSegment::Identifier(identifier) => identifier.span,
        PathSegment::Super(span) => *span,
    }
}

fn declaration_origins(
    entities: &BTreeSet<EntityId>,
    metadata: &BTreeMap<EntityId, Entity>,
) -> Vec<OriginRef> {
    let mut origins = entities
        .iter()
        .filter_map(|entity| metadata.get(entity)?.declared_at.clone())
        .collect::<Vec<_>>();
    origins.sort();
    origins.dedup();
    origins
}

fn sorted_delivery_origins(deliveries: &BTreeMap<EntityId, Delivery>) -> Vec<OriginRef> {
    let mut origins = deliveries
        .values()
        .filter_map(|delivery| delivery.origin.clone())
        .collect::<Vec<_>>();
    origins.sort();
    origins.dedup();
    origins
}

fn first_binding_diagnostic(
    core: LibraryId,
    module: &ModuleRef,
    table: &BindingTable,
) -> Option<ProjectDiagnostic> {
    let mut diagnostics = Vec::new();
    for ((namespace, name), deliveries) in table {
        let Some(public_namespace) = namespace.public() else {
            continue;
        };
        let origins = sorted_delivery_origins(deliveries);
        let primary = origins.first().cloned();
        let mut record = |diagnostic: ProjectDiagnostic| {
            diagnostics.push((
                (
                    primary.as_ref().map(|origin| origin.span),
                    diagnostic_kind_rank(&diagnostic.kind),
                    *namespace,
                    name.clone(),
                ),
                diagnostic,
            ));
        };
        if is_protected_name(*namespace, name)
            && !deliveries.keys().all(|target| {
                (target.module.is_language() && target.name.as_str() == name.as_str())
                    || is_exact_core_binding(core, name, target)
            })
        {
            record(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::ReservedLanguageBinding {
                    library: module.library(),
                    namespace: public_namespace,
                    name: name.clone(),
                },
                primary: primary.clone(),
                related: Vec::new(),
            });
        }
        if deliveries.len() > 1 {
            record(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::NameConflict {
                    library: module.library(),
                    namespace: public_namespace,
                    name: name.clone(),
                },
                primary: primary.clone(),
                related: origins.iter().skip(1).cloned().collect(),
            });
        }
        if *namespace == Namespace::Type && name == "Self" {
            record(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::InvalidSelf {
                    library: module.library(),
                },
                primary: primary.clone(),
                related: Vec::new(),
            });
        }
    }
    diagnostics
        .into_iter()
        .min_by(|(left, _), (right, _)| left.cmp(right))
        .map(|(_, diagnostic)| diagnostic)
}

fn first_stage_diagnostic(
    diagnostics: Vec<(ModuleRef, ProjectDiagnostic)>,
) -> Option<ProjectDiagnostic> {
    diagnostics
        .into_iter()
        .min_by(|(left_module, left), (right_module, right)| {
            left_module
                .cmp(right_module)
                .then_with(|| {
                    left.primary
                        .as_ref()
                        .map(|origin| origin.span)
                        .cmp(&right.primary.as_ref().map(|origin| origin.span))
                })
                .then_with(|| {
                    diagnostic_kind_rank(&left.kind).cmp(&diagnostic_kind_rank(&right.kind))
                })
        })
        .map(|(_, diagnostic)| diagnostic)
}

fn diagnostic_kind_rank(kind: &ProjectDiagnosticKind) -> u8 {
    match kind {
        ProjectDiagnosticKind::MissingEntryLibrary { .. } => 0,
        ProjectDiagnosticKind::MissingCoreLibrary { .. } => 1,
        ProjectDiagnosticKind::InvalidDependencyAlias { .. } => 2,
        ProjectDiagnosticKind::MissingDependencyTarget { .. } => 3,
        ProjectDiagnosticKind::LibraryDependencyCycle { .. } => 4,
        ProjectDiagnosticKind::MissingDirectCoreDependency { .. } => 5,
        ProjectDiagnosticKind::Frontend(_) => 6,
        ProjectDiagnosticKind::InvalidModuleName { .. } => 7,
        ProjectDiagnosticKind::ModuleBodyConflict { .. } => 8,
        ProjectDiagnosticKind::GenerateUnsupported => 9,
        ProjectDiagnosticKind::PathEscapesRoot => 10,
        ProjectDiagnosticKind::InvalidPath => 11,
        ProjectDiagnosticKind::NameConflict { .. } => 12,
        ProjectDiagnosticKind::MemberConflict { .. } => 13,
        ProjectDiagnosticKind::ReservedLanguageBinding { .. } => 14,
        ProjectDiagnosticKind::MissingCoreRole { .. } => 15,
        ProjectDiagnosticKind::InvalidCoreRole(_) => 16,
        ProjectDiagnosticKind::UnresolvedImport { .. } => 17,
        ProjectDiagnosticKind::AmbiguousImport { .. } => 18,
        ProjectDiagnosticKind::InaccessibleImport { .. } => 19,
        ProjectDiagnosticKind::ImportCycle { .. } => 20,
        ProjectDiagnosticKind::PrivateReExport { .. } => 21,
        ProjectDiagnosticKind::MissingConstructorOwner { .. } => 22,
        ProjectDiagnosticKind::UnresolvedName { .. } => 23,
        ProjectDiagnosticKind::AmbiguousName { .. } => 24,
        ProjectDiagnosticKind::InaccessibleName { .. } => 25,
        ProjectDiagnosticKind::DuplicateBinding { .. } => 26,
        ProjectDiagnosticKind::PatternBindingMismatch => 27,
        ProjectDiagnosticKind::InvalidSelf { .. } => 28,
        ProjectDiagnosticKind::InvalidSupertrait { .. } => 29,
        ProjectDiagnosticKind::TraitInheritanceCycle => 30,
        ProjectDiagnosticKind::EffectAliasCycle => 31,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_LIBRARY: LibraryId = LibraryId(0);
    const TEST_CORE: LibraryId = LibraryId(u32::MAX);
    const TEST_CORE_SOURCE: &str = include_str!("../../../core/root.vorton");

    fn project(root: &str, modules: Vec<(Vec<&str>, &str)>) -> ProjectSources {
        graph(
            TEST_LIBRARY,
            vec![(TEST_LIBRARY, library(root, modules, vec![]))],
        )
    }

    fn library(
        root: &str,
        modules: Vec<(Vec<&str>, &str)>,
        dependencies: Vec<(&str, LibraryId)>,
    ) -> LibrarySources {
        LibrarySources {
            root: root.to_owned(),
            modules: modules
                .into_iter()
                .map(|(path, source)| {
                    (
                        FileModulePath::new(path).expect("test module path is valid"),
                        source.to_owned(),
                    )
                })
                .collect(),
            dependencies: dependencies
                .into_iter()
                .map(|(alias, target)| (alias.to_owned(), target))
                .collect(),
        }
    }

    fn graph(entry: LibraryId, mut libraries: Vec<(LibraryId, LibrarySources)>) -> ProjectSources {
        for (library_id, library) in &mut libraries {
            if *library_id != TEST_CORE
                && !library
                    .dependencies
                    .values()
                    .any(|target| *target == TEST_CORE)
            {
                library
                    .dependencies
                    .insert("test_core".to_owned(), TEST_CORE);
            }
        }
        if !libraries.iter().any(|(library, _)| *library == TEST_CORE) {
            libraries.push((
                TEST_CORE,
                LibrarySources {
                    root: TEST_CORE_SOURCE.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ));
        }
        raw_graph(entry, TEST_CORE, libraries)
    }

    fn raw_graph(
        entry: LibraryId,
        core: LibraryId,
        libraries: Vec<(LibraryId, LibrarySources)>,
    ) -> ProjectSources {
        ProjectSources {
            entry,
            core,
            libraries: libraries.into_iter().collect(),
        }
    }

    fn project_with_core_source(core_source: String) -> ProjectSources {
        graph(
            TEST_LIBRARY,
            vec![
                (TEST_LIBRARY, library("", vec![], vec![])),
                (TEST_CORE, library(&core_source, vec![], vec![])),
            ],
        )
    }

    fn replaced_core_source(needle: &str, replacement: &str) -> String {
        let source = TEST_CORE_SOURCE.replace("\r\n", "\n");
        assert_eq!(
            source.matches(needle).count(),
            1,
            "the core mutation must replace exactly one normalized source fragment"
        );
        source.replacen(needle, replacement, 1)
    }

    fn assert_invalid_core(
        core_source: String,
        expected_role: &str,
        expected_member: Option<&str>,
        expected_issue: CoreRoleIssue,
    ) {
        let diagnostic = resolve_project(&project_with_core_source(core_source))
            .expect_err("an invalid official core profile must be rejected");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::InvalidCoreRole(Box::new(CoreRoleDiagnostic {
                core: TEST_CORE,
                role: expected_role.to_owned(),
                member: expected_member.map(str::to_owned),
                issue: expected_issue,
            }))
        );
        let primary = diagnostic
            .primary
            .expect("invalid core role has a source origin");
        assert_eq!(primary.library, TEST_CORE);
        assert_eq!(primary.source, SourceRef::Root);
        assert!(diagnostic.related.is_empty());
    }

    fn project_with_reachable_libraries(
        libraries: Vec<(LibraryId, LibrarySources)>,
    ) -> ProjectSources {
        let dependencies = libraries
            .iter()
            .map(|(library, _)| (format!("library_{}", library.0), *library))
            .collect();
        let mut all = vec![(
            TEST_LIBRARY,
            LibrarySources {
                root: String::new(),
                modules: BTreeMap::new(),
                dependencies,
            },
        )];
        all.extend(libraries);
        graph(TEST_LIBRARY, all)
    }

    fn single_library_project(
        root: String,
        modules: BTreeMap<FileModulePath, String>,
    ) -> ProjectSources {
        graph(
            TEST_LIBRARY,
            vec![(
                TEST_LIBRARY,
                LibrarySources {
                    root,
                    modules,
                    dependencies: BTreeMap::new(),
                },
            )],
        )
    }

    fn module_ref(library: LibraryId, path: &[&str]) -> ModuleRef {
        ModuleRef::Source {
            library,
            path: path.iter().map(|segment| (*segment).to_owned()).collect(),
        }
    }

    fn module_body<'a>(resolved: &'a ResolvedProject, path: &[&str]) -> &'a ResolvedModuleBody {
        module_body_in(resolved, TEST_LIBRARY, path)
    }

    fn module_body_in<'a>(
        resolved: &'a ResolvedProject,
        library: LibraryId,
        path: &[&str],
    ) -> &'a ResolvedModuleBody {
        resolved
            .modules
            .get(&module_ref(library, path))
            .and_then(|module| module.body.as_ref())
            .expect("resolved module body exists")
    }

    fn function<'a>(body: &'a ResolvedModuleBody, name: &str) -> &'a ResolvedFunction {
        body.declarations
            .iter()
            .find_map(|declaration| {
                (declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == name))
                .then_some(&declaration.kind)
            })
            .and_then(|kind| match kind {
                ResolvedDeclarationKind::Function(function) => Some(function),
                _ => None,
            })
            .expect("resolved function exists")
    }

    fn exact(reference: &ResolvedReference) -> &EntityId {
        match reference {
            ResolvedReference::Exact { target, .. } => target,
            ResolvedReference::Selection { .. } => panic!("expected an exact reference"),
        }
    }

    fn path_expression(expression: &ResolvedExpr) -> &ResolvedReference {
        match &expression.kind {
            ResolvedExprKind::Path(reference) => reference,
            _ => panic!("expected path expression"),
        }
    }

    fn named_type_reference(ty: &ResolvedType) -> &ResolvedReference {
        match &ty.kind {
            ResolvedTypeKind::Named(named) => &named.reference,
            _ => panic!("expected a named type"),
        }
    }

    fn parameter_type(annotation: &ResolvedParameterAnnotation) -> &ResolvedType {
        match annotation {
            ResolvedParameterAnnotation::Type(ty) => ty,
            ResolvedParameterAnnotation::Shape(_) => panic!("expected an actual parameter type"),
        }
    }

    fn actual_return_type(annotation: &ResolvedReturnAnnotation) -> &ResolvedType {
        match annotation {
            ResolvedReturnAnnotation::Type(ty) => ty,
            ResolvedReturnAnnotation::Shape(_) => panic!("expected an actual return type"),
        }
    }

    #[test]
    fn validates_abstract_file_module_paths() {
        assert!(FileModulePath::new(["parser", "lexer"]).is_ok());
        assert!(FileModulePath::new(["type", "alias", "_"]).is_ok());
        for invalid in [
            Vec::<&str>::new(),
            vec![""],
            vec!["not-valid"],
            vec!["self"],
            vec!["root"],
        ] {
            assert!(FileModulePath::new(invalid).is_err());
        }
    }

    #[test]
    fn official_core_resolves_as_entry_and_keeps_every_role_source_owned() {
        let resolved = resolve_project(&raw_graph(
            TEST_CORE,
            TEST_CORE,
            vec![(TEST_CORE, library(TEST_CORE_SOURCE, vec![], vec![]))],
        ))
        .expect("the tracked official core resolves as its own entry");
        assert_eq!(resolved.entry, TEST_CORE);
        assert_eq!(resolved.core, TEST_CORE);

        let roles = &resolved.core_roles;
        let declarations = [
            &roles.option.declaration,
            &roles.ordering.declaration,
            &roles.partial_eq.declaration,
            &roles.eq,
            &roles.partial_ord.declaration,
            &roles.ord.declaration,
            &roles.clone.declaration,
            &roles.copy,
            &roles.drop.declaration,
            &roles.display.declaration,
            &roles.debug.declaration,
            &roles.hash.declaration,
            &roles.fn_once,
            &roles.fn_mut,
            &roles.function,
            &roles.iterator.declaration,
            &roles.iterable.declaration,
        ];
        assert_eq!(declarations.len(), CORE_ENUMS.len() + CORE_TRAITS.len());
        assert!(declarations.iter().all(|identity| {
            identity.module == ModuleRef::root(TEST_CORE)
                && matches!(
                    identity.site,
                    EntitySite::Source(OriginRef {
                        library: TEST_CORE,
                        source: SourceRef::Root,
                        ..
                    })
                )
                && resolved
                    .entities
                    .get(*identity)
                    .is_some_and(|entity| entity.public && entity.declared_at.is_some())
        }));
        assert_eq!(
            declarations
                .iter()
                .filter(|identity| identity.kind == EntityKind::Enum)
                .count(),
            2
        );
        assert_eq!(
            declarations
                .iter()
                .filter(|identity| identity.kind == EntityKind::Trait)
                .count(),
            15
        );

        let members = [
            (&roles.option.some, &roles.option.declaration),
            (&roles.option.none, &roles.option.declaration),
            (&roles.ordering.less, &roles.ordering.declaration),
            (&roles.ordering.equal, &roles.ordering.declaration),
            (&roles.ordering.greater, &roles.ordering.declaration),
            (&roles.partial_eq.method, &roles.partial_eq.declaration),
            (&roles.partial_ord.method, &roles.partial_ord.declaration),
            (&roles.ord.method, &roles.ord.declaration),
            (&roles.clone.method, &roles.clone.declaration),
            (&roles.drop.method, &roles.drop.declaration),
            (&roles.display.method, &roles.display.declaration),
            (&roles.debug.method, &roles.debug.declaration),
            (&roles.hash.method, &roles.hash.declaration),
            (&roles.iterator.item, &roles.iterator.declaration),
            (&roles.iterator.next, &roles.iterator.declaration),
            (&roles.iterable.item, &roles.iterable.declaration),
            (&roles.iterable.iter_type, &roles.iterable.declaration),
            (&roles.iterable.iter, &roles.iterable.declaration),
        ];
        assert!(members.iter().all(|(identity, owner)| {
            identity.module.source_library() == Some(TEST_CORE)
                && resolved.entities.get(*identity).is_some_and(|entity| {
                    entity.declared_at.is_some() && entity.owner.as_ref() == Some(*owner)
                })
        }));
        assert_eq!(
            resolved
                .entities
                .keys()
                .filter(|identity| {
                    identity.module.is_language()
                        && (CORE_ENUMS.contains(&identity.name.as_str())
                            || CORE_TRAITS.contains(&identity.name.as_str()))
                })
                .count(),
            0,
            "migrated roles have no parallel Language entity"
        );
        assert_eq!(
            resolved
                .entities
                .keys()
                .filter(|identity| {
                    identity.name == "eq"
                        && identity
                            .owner
                            .as_ref()
                            .is_some_and(|owner| owner.name == "Eq")
                })
                .count(),
            0,
            "Eq has no legacy eq member"
        );
    }

    #[test]
    fn designated_core_identity_is_alias_independent_and_shared_once_in_a_diamond() {
        fn resolve_with(core: LibraryId, aliases: [&str; 3]) -> ResolvedProject {
            let app = LibraryId(10);
            let left = LibraryId(20);
            let right = LibraryId(30);
            resolve_project(&raw_graph(
                app,
                core,
                vec![
                    (
                        app,
                        library(
                            "use left::keep_left; use right::keep_right; fn keep(value: Option<Int>) -> Option<Int> { keep_right(keep_left(value)) }",
                            vec![],
                            vec![
                                ("left", left),
                                ("right", right),
                                (aliases[0], core),
                                ("same_core", core),
                            ],
                        ),
                    ),
                    (
                        left,
                        library(
                            "pub fn keep_left(value: Option<Int>) -> Option<Int> { value }",
                            vec![],
                            vec![(aliases[1], core)],
                        ),
                    ),
                    (
                        right,
                        library(
                            "pub fn keep_right(value: Option<Int>) -> Option<Int> { value }",
                            vec![],
                            vec![(aliases[2], core)],
                        ),
                    ),
                    (core, library(TEST_CORE_SOURCE, vec![], vec![])),
                ],
            ))
            .expect("all diamond consumers point directly at the designated core")
        }

        let first = resolve_with(LibraryId(40), ["official", "runtime", "foundation"]);
        let second = resolve_with(LibraryId(400), ["foundation", "official", "runtime"]);
        assert_eq!(
            first.core_roles.option.declaration.module.source_library(),
            Some(LibraryId(40))
        );
        assert_eq!(
            second.core_roles.option.declaration.module.source_library(),
            Some(LibraryId(400))
        );
        for resolved in [&first, &second] {
            assert_eq!(
                resolved
                    .entities
                    .keys()
                    .filter(
                        |identity| identity.kind == EntityKind::Enum && identity.name == "Option"
                    )
                    .count(),
                1
            );
        }
    }

    #[test]
    fn core_graph_input_errors_precede_source_and_keep_real_ids() {
        let missing_entry = LibraryId(7);
        let missing_core = LibraryId(8);
        let diagnostic = resolve_project(&raw_graph(missing_entry, missing_core, vec![]))
            .expect_err("missing entry is the first graph check");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingEntryLibrary {
                entry: missing_entry
            }
        );

        let diagnostic = resolve_project(&raw_graph(
            TEST_LIBRARY,
            missing_core,
            vec![(TEST_LIBRARY, library("@source_is_later", vec![], vec![]))],
        ))
        .expect_err("missing core follows the entry check and precedes source");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingCoreLibrary { core: missing_core }
        );
        assert!(diagnostic.primary.is_none());

        let dependency = LibraryId(1);
        let diagnostic = resolve_project(&raw_graph(
            TEST_LIBRARY,
            TEST_CORE,
            vec![
                (
                    TEST_LIBRARY,
                    library("", vec![], vec![("dependency", dependency)]),
                ),
                (dependency, library("", vec![], vec![("app", TEST_LIBRARY)])),
                (TEST_CORE, library(TEST_CORE_SOURCE, vec![], vec![])),
            ],
        ))
        .expect_err("ordinary graph cycles precede direct-core checks");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::LibraryDependencyCycle { .. }
        ));

        let diagnostic = resolve_project(&raw_graph(
            TEST_LIBRARY,
            TEST_CORE,
            vec![
                (TEST_LIBRARY, library("@source_is_later", vec![], vec![])),
                (TEST_CORE, library(TEST_CORE_SOURCE, vec![], vec![])),
            ],
        ))
        .expect_err("a reachable non-core library needs one direct core edge");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingDirectCoreDependency {
                owner: TEST_LIBRARY,
                core: TEST_CORE,
            }
        );
        assert!(diagnostic.primary.is_none());

        resolve_project(&raw_graph(
            TEST_CORE,
            TEST_CORE,
            vec![
                (TEST_CORE, library(TEST_CORE_SOURCE, vec![], vec![])),
                (TEST_LIBRARY, library("@unreachable", vec![], vec![])),
            ],
        ))
        .expect(
            "unreachable libraries need structural validity but no direct core edge or source scan",
        );
    }

    #[test]
    fn core_frontend_errors_use_the_real_core_source_origin() {
        let diagnostic = resolve_project(&project_with_core_source("@invalid_core".to_owned()))
            .expect_err("the selected core is parsed as ordinary source");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::Frontend(_)
        ));
        let primary = diagnostic
            .primary
            .expect("frontend error has a source origin");
        assert_eq!(primary.library, TEST_CORE);
        assert_eq!(primary.source, SourceRef::Root);
    }

    #[test]
    fn protected_core_type_names_cannot_be_rebound_outside_the_core_root() {
        for source in [
            "struct Option {}",
            "enum Ordering {}",
            "trait PartialEq {}",
            "type Copy = Int;",
            "fn bad<Display>() {}",
            "trait Bad { type Iterable; }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("a protected core Type binding cannot be replaced");
            assert!(
                matches!(
                    diagnostic.kind,
                    ProjectDiagnosticKind::ReservedLanguageBinding {
                        namespace: NameNamespace::Type,
                        ..
                    }
                ),
                "{source}: {diagnostic:?}"
            );
        }
        resolve_project(&project(
            "fn Option() -> Int { 1 } effect Display {} fn keep() -> Int { Option() }",
            vec![],
        ))
        .expect("the protected spellings remain independent in Value and Effect namespaces");
    }

    #[test]
    fn missing_core_role_has_no_fabricated_source_span() {
        let source = replaced_core_source(
            "pub trait Display {\n    fn to_str(self: &Self) -> Str;\n}\n\n",
            "",
        );
        let diagnostic = resolve_project(&project_with_core_source(source))
            .expect_err("a required role cannot be synthesized");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingCoreRole {
                core: TEST_CORE,
                role: "Display".to_owned(),
            }
        );
        assert!(diagnostic.primary.is_none());
        assert!(diagnostic.related.is_empty());
    }

    #[test]
    fn rejects_wrong_core_declaration_category() {
        assert_invalid_core(
            replaced_core_source(
                "pub trait Display {\n    fn to_str(self: &Self) -> Str;\n}",
                "pub type Display = Str;",
            ),
            "Display",
            None,
            CoreRoleIssue::DeclarationKind,
        );
    }

    #[test]
    fn rejects_wrong_core_generic_arity_before_resolving_its_body() {
        assert_invalid_core(
            replaced_core_source("pub enum Option<T>", "pub enum Option"),
            "Option",
            None,
            CoreRoleIssue::GenericArity {
                expected: 1,
                actual: 0,
            },
        );
    }

    #[test]
    fn rejects_missing_or_wrong_core_members() {
        assert_invalid_core(
            replaced_core_source("    fn debug(self: &Self) -> Str;\n", ""),
            "Debug",
            None,
            CoreRoleIssue::MemberSet,
        );
        assert_invalid_core(
            replaced_core_source("    fn hash(self: &Self) -> Int;", "    type hash;"),
            "Hash",
            Some("hash"),
            CoreRoleIssue::MemberKind,
        );
    }

    #[test]
    fn rejects_wrong_core_receiver_and_result_profiles() {
        assert_invalid_core(
            replaced_core_source(
                "fn clone(self: &Self) -> Self;",
                "fn clone(value: &Self) -> Self;",
            ),
            "Clone",
            Some("clone"),
            CoreRoleIssue::Receiver,
        );
        assert_invalid_core(
            replaced_core_source(
                "fn drop(self: &mut Self) -> Unit;",
                "fn drop(self: &Self) -> Unit;",
            ),
            "Drop",
            Some("drop"),
            CoreRoleIssue::ParameterMode {
                index: 0,
                expected: ParameterMode::MutBorrow,
                actual: Some(ParameterMode::Borrow),
            },
        );
        assert_invalid_core(
            replaced_core_source(
                "fn clone(self: &Self) -> Self;",
                "fn clone(self: &Self) -> Bool;",
            ),
            "Clone",
            Some("clone"),
            CoreRoleIssue::ReturnType,
        );
    }

    #[test]
    fn rejects_wrong_core_effect_profile() {
        assert_invalid_core(
            replaced_core_source(
                "fn eq(self: &Self, other: &Self) -> Bool with {};",
                "fn eq(self: &Self, other: &Self) -> Bool;",
            ),
            "PartialEq",
            Some("eq"),
            CoreRoleIssue::EffectProfile,
        );
        assert_invalid_core(
            replaced_core_source(
                "fn clone(self: &Self) -> Self;",
                "fn clone(self: &Self) -> Self with {};",
            ),
            "Clone",
            Some("clone"),
            CoreRoleIssue::EffectProfile,
        );
    }

    #[test]
    fn rejects_wrong_core_enum_supertrait_and_associated_profiles() {
        assert_invalid_core(
            replaced_core_source("    Some(T),", "    Some(Int),"),
            "Option",
            Some("Some"),
            CoreRoleIssue::VariantPayload,
        );
        assert_invalid_core(
            replaced_core_source("    Less,\n    Equal,", "    Equal,\n    Less,"),
            "Ordering",
            None,
            CoreRoleIssue::VariantSet,
        );
        assert_invalid_core(
            replaced_core_source("pub trait Copy: Clone {}", "pub trait Copy {}"),
            "Copy",
            None,
            CoreRoleIssue::Supertraits,
        );
        assert_invalid_core(
            replaced_core_source("type Iter: Iterator<Item = Self::Item>;", "type Iter;"),
            "Iterable",
            Some("Iter"),
            CoreRoleIssue::AssociatedTypeBounds,
        );
    }

    #[test]
    fn resolves_a_dependency_diamond_with_one_shared_source_identity() {
        let app = LibraryId(10);
        let left = LibraryId(20);
        let right = LibraryId(30);
        let shared = LibraryId(40);
        let unused = LibraryId(50);
        let libraries = vec![
            (
                unused,
                library("pub fn available() -> Int { 1 }", vec![], vec![]),
            ),
            (
                shared,
                library("pub struct Shared { pub value: Int }", vec![], vec![]),
            ),
            (
                right,
                library("pub use shared::Shared;", vec![], vec![("shared", shared)]),
            ),
            (
                left,
                library("pub use shared::Shared;", vec![], vec![("shared", shared)]),
            ),
            (
                app,
                library(
                    "use left::Shared; use right::Shared; fn keep(value: Shared) -> Shared { value }",
                    vec![],
                    vec![("left", left), ("right", right), ("unused", unused)],
                ),
            ),
        ];
        let resolved = resolve_project(&graph(app, libraries.clone()))
            .expect("the dependency diamond resolves as one project");
        let reordered = resolve_project(&graph(app, libraries.into_iter().rev().collect()))
            .expect("library insertion order does not change the result");
        assert_eq!(resolved, reordered);
        assert_eq!(resolved.entry, app);
        assert_eq!(resolved.dependencies.len(), 6);
        assert_eq!(resolved.dependencies[&left]["shared"], shared);
        assert_eq!(resolved.dependencies[&right]["shared"], shared);

        let keep = function(module_body_in(&resolved, app, &[]), "keep");
        let parameter = exact(named_type_reference(parameter_type(
            keep.parameters[0]
                .annotation
                .as_ref()
                .expect("parameter type"),
        )));
        let returned = exact(named_type_reference(actual_return_type(
            keep.return_type.as_ref().expect("return type"),
        )));
        assert_eq!(parameter, returned);
        assert_eq!(parameter.module.source_library(), Some(shared));
        assert_eq!(
            resolved
                .entities
                .keys()
                .filter(|entity| entity.kind == EntityKind::Struct && entity.name == "Shared")
                .count(),
            1
        );
        assert!(
            resolved
                .entities
                .contains_key(&module_id(&ModuleRef::root(shared)))
        );
        assert!(
            module_body_in(&resolved, unused, &[])
                .declarations
                .iter()
                .any(|declaration| declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == "available"))
        );
    }

    #[test]
    fn validates_the_complete_library_graph_before_source_frontend() {
        let entry = LibraryId(1);
        let second = LibraryId(2);
        let third = LibraryId(3);
        let missing = LibraryId(99);

        let diagnostic =
            resolve_project(&graph(entry, vec![])).expect_err("the entry library must be present");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingEntryLibrary { entry }
        );
        assert!(diagnostic.primary.is_none() && diagnostic.related.is_empty());

        let diagnostic = resolve_project(&graph(
            entry,
            vec![(entry, library("@bad", vec![], vec![("not-valid", missing)]))],
        ))
        .expect_err("alias validation precedes missing targets and frontend");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::InvalidDependencyAlias {
                owner: entry,
                alias: "not-valid".to_owned(),
            }
        );
        assert!(diagnostic.primary.is_none() && diagnostic.related.is_empty());

        let diagnostic = resolve_project(&graph(
            entry,
            vec![(
                entry,
                library("fn ok() {}", vec![], vec![("dependency", missing)]),
            )],
        ))
        .expect_err("every dependency target must exist");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingDependencyTarget {
                owner: entry,
                alias: "dependency".to_owned(),
                target: missing,
            }
        );

        let self_cycle = resolve_project(&graph(
            entry,
            vec![(
                entry,
                library("fn ok() {}", vec![], vec![("self_dep", entry)]),
            )],
        ))
        .expect_err("self-dependencies are cycles");
        assert_eq!(
            self_cycle.kind,
            ProjectDiagnosticKind::LibraryDependencyCycle {
                cycle: vec![entry, entry],
            }
        );

        let cyclic = vec![
            (
                third,
                library("fn third() {}", vec![], vec![("first", entry)]),
            ),
            (
                entry,
                library("fn first() {}", vec![], vec![("second", second)]),
            ),
            (
                second,
                library("fn second() {}", vec![], vec![("third", third)]),
            ),
        ];
        let forward = resolve_project(&graph(entry, cyclic.clone()))
            .expect_err("a multi-library cycle is rejected");
        let reverse = resolve_project(&graph(entry, cyclic.into_iter().rev().collect()))
            .expect_err("map construction order does not change the cycle");
        assert_eq!(forward, reverse);
        assert_eq!(
            forward.kind,
            ProjectDiagnosticKind::LibraryDependencyCycle {
                cycle: vec![entry, second, third, entry],
            }
        );

        let unreachable = LibraryId(10);
        resolve_project(&graph(
            entry,
            vec![
                (entry, library("fn ok() {}", vec![], vec![])),
                (unreachable, library("@bad", vec![], vec![])),
            ],
        ))
        .expect("unreachable source text is not parsed");
        let diagnostic = resolve_project(&graph(
            entry,
            vec![
                (entry, library("fn ok() {}", vec![], vec![])),
                (
                    unreachable,
                    library("fn unused() {}", vec![], vec![("lost", missing)]),
                ),
            ],
        ))
        .expect_err("unreachable library edges still belong to the input graph");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingDependencyTarget {
                owner,
                ref alias,
                target,
            } if owner == unreachable && alias == "lost" && target == missing
        ));

        resolve_project(&graph(
            entry,
            vec![
                (
                    entry,
                    library(
                        "fn ok() {}",
                        vec![],
                        vec![("_", second), ("generate", third)],
                    ),
                ),
                (second, library("fn second() {}", vec![], vec![])),
                (third, library("fn third() {}", vec![], vec![])),
            ],
        ))
        .expect("contextual identifiers and underscore remain valid aliases");

        for alias in ["self", "super", "root", "not-valid"] {
            let diagnostic = resolve_project(&graph(
                entry,
                vec![
                    (entry, library("fn ok() {}", vec![], vec![(alias, second)])),
                    (second, library("fn second() {}", vec![], vec![])),
                ],
            ))
            .expect_err("reserved or malformed dependency alias is rejected");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::InvalidDependencyAlias {
                    owner,
                    alias: ref actual,
                } if owner == entry && actual == alias
            ));
        }

        let reserved = resolve_project(&graph(
            entry,
            vec![
                (entry, library("fn ok() {}", vec![], vec![("Int", second)])),
                (second, library("fn second() {}", vec![], vec![])),
            ],
        ))
        .expect_err("dependency aliases retain Type namespace reservations");
        assert!(matches!(
            reserved.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding {
                library,
                namespace: NameNamespace::Type,
                ref name,
            } if library == entry && name == "Int"
        ));
        assert!(reserved.primary.is_none());

        let invalid_self = resolve_project(&graph(
            entry,
            vec![
                (entry, library("fn ok() {}", vec![], vec![("Self", second)])),
                (second, library("fn second() {}", vec![], vec![])),
            ],
        ))
        .expect_err("Self remains unavailable as a root Type binding");
        assert_eq!(
            invalid_self.kind,
            ProjectDiagnosticKind::InvalidSelf { library: entry }
        );
        assert!(invalid_self.primary.is_none());

        let file_alias_conflict = resolve_project(&graph(
            entry,
            vec![
                (
                    entry,
                    library("fn ok() {}", vec![(vec!["dep"], "")], vec![("dep", second)]),
                ),
                (second, library("fn second() {}", vec![], vec![])),
            ],
        ))
        .expect_err("a file module and dependency alias cannot share a Type binding");
        assert!(matches!(
            file_alias_conflict.kind,
            ProjectDiagnosticKind::NameConflict {
                library,
                namespace: NameNamespace::Type,
                ref name,
            } if library == entry && name == "dep"
        ));
        assert!(file_alias_conflict.primary.is_none());
    }

    fn unreachable_library_chain(depth: u32) -> ProjectSources {
        let core = LibraryId(0);
        let mut libraries = BTreeMap::from([(core, library(TEST_CORE_SOURCE, vec![], vec![]))]);
        for index in 1..=depth {
            let dependencies = if index < depth {
                BTreeMap::from([("next".to_owned(), LibraryId(index + 1))])
            } else {
                BTreeMap::new()
            };
            libraries.insert(
                LibraryId(index),
                LibrarySources {
                    root: String::new(),
                    modules: BTreeMap::new(),
                    dependencies,
                },
            );
        }
        ProjectSources {
            entry: core,
            core,
            libraries,
        }
    }

    #[test]
    fn validates_a_deep_unreachable_library_chain_without_recursing() {
        let resolved = crate::resolve_project(&unreachable_library_chain(8192))
            .expect("a legal unreachable chain does not consume the process call stack");
        assert_eq!(resolved.entry, LibraryId(0));
        assert_eq!(resolved.core, LibraryId(0));
        assert_eq!(resolved.modules.len(), 1);
        assert!(
            resolved
                .modules
                .contains_key(&ModuleRef::root(LibraryId(0)))
        );
    }

    #[test]
    fn a_deep_dependency_back_edge_reports_only_the_closed_cycle() {
        let depth = 8192;
        let mut sources = unreachable_library_chain(depth);
        sources
            .libraries
            .get_mut(&LibraryId(depth))
            .expect("chain tail exists")
            .dependencies
            .insert("back".to_owned(), LibraryId(depth - 2));
        let diagnostic =
            crate::resolve_project(&sources).expect_err("the back edge closes a cycle");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::LibraryDependencyCycle {
                cycle: vec![
                    LibraryId(depth - 2),
                    LibraryId(depth - 1),
                    LibraryId(depth),
                    LibraryId(depth - 2),
                ],
            }
        );
    }

    #[test]
    fn each_library_closes_its_own_file_sources_before_consumers_resolve() {
        let app = LibraryId(1);
        let dependency = LibraryId(2);
        let unopened = FileModulePath::new(["secret"]).expect("module key");
        let diagnostic = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use dep::secret::hidden; fn main() {}",
                        vec![],
                        vec![("dep", dependency)],
                    ),
                ),
                (
                    dependency,
                    LibrarySources {
                        root: String::new(),
                        modules: BTreeMap::from([(
                            unopened.clone(),
                            "pub fn hidden() -> Int { 1 }".to_owned(),
                        )]),
                        dependencies: BTreeMap::new(),
                    },
                ),
            ],
        ))
        .expect_err("a consumer import cannot open a dependency file body");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedImport { ref path }
                if path == "dep::secret::hidden"
        ));
        assert_eq!(
            diagnostic.primary.expect("consumer use origin").library,
            app
        );

        let diagnostic = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use dep::secret::hidden; fn main() {}",
                        vec![],
                        vec![("dep", dependency)],
                    ),
                ),
                (
                    dependency,
                    LibrarySources {
                        root: String::new(),
                        modules: BTreeMap::from([(unopened, "@bad".to_owned())]),
                        dependencies: BTreeMap::new(),
                    },
                ),
            ],
        ))
        .expect_err("an unopened dependency file never reaches frontend");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedImport { .. }
        ));

        let resolved = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use local::Local; use dep::Remote; fn use_both(left: Local, right: Remote) {}",
                        vec![(vec!["local"], "pub struct Local {}")],
                        vec![("dep", dependency)],
                    ),
                ),
                (
                    dependency,
                    library(
                        "pub use local::Remote;",
                        vec![(vec!["local"], "pub struct Remote {}")],
                        vec![],
                    ),
                ),
            ],
        ))
        .expect("each library opens only its own same-key file source");
        let use_both = function(module_body_in(&resolved, app, &[]), "use_both");
        let left = exact(named_type_reference(parameter_type(
            use_both.parameters[0]
                .annotation
                .as_ref()
                .expect("local parameter type"),
        )));
        let right = exact(named_type_reference(parameter_type(
            use_both.parameters[1]
                .annotation
                .as_ref()
                .expect("dependency parameter type"),
        )));
        assert_eq!(left.module.source_library(), Some(app));
        assert_eq!(right.module.source_library(), Some(dependency));
        assert_eq!(left.module.path(), ["local"]);
        assert_eq!(right.module.path(), ["local"]);

        let escaped = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library("fn main() {}", vec![], vec![("dep", dependency)]),
                ),
                (dependency, library("use super::missing;", vec![], vec![])),
            ],
        ))
        .expect_err("super cannot cross a dependency root");
        assert_eq!(escaped.kind, ProjectDiagnosticKind::PathEscapesRoot);
        assert_eq!(
            escaped.primary.expect("dependency root origin").library,
            dependency
        );
    }

    #[test]
    fn dependency_visibility_and_facades_preserve_original_targets() {
        let app = LibraryId(1);
        let facade = LibraryId(2);
        let origin = LibraryId(3);
        let resolved = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use api::Public; use api::facade::Public as ViaFacade; use api::Choice; use api::One; fn make(left: Public, right: ViaFacade) -> Choice { One(1) } mod feature { use root::api::Public; fn nested(value: Public) {} }",
                        vec![],
                        vec![("api", facade)],
                    ),
                ),
                (
                    facade,
                    library(
                        "pub use actual::Public; pub use actual as facade; pub use actual::Choice; pub use actual::Choice::{One};",
                        vec![],
                        vec![("actual", origin)],
                    ),
                ),
                (
                    origin,
                    library(
                        "pub struct Public {} struct Private {} pub enum Choice { One(Int) }",
                        vec![],
                        vec![],
                    ),
                ),
            ],
        ))
        .expect("explicit entity, module, and constructor facades resolve");
        let root_facade = module_body_in(&resolved, facade, &[])
            .imports
            .iter()
            .find(|import| import.local_name == "facade")
            .expect("dependency root facade import");
        assert_eq!(root_facade.target, module_id(&ModuleRef::root(origin)));
        let make = function(module_body_in(&resolved, app, &[]), "make");
        let left = exact(named_type_reference(parameter_type(
            make.parameters[0]
                .annotation
                .as_ref()
                .expect("direct facade type"),
        )));
        let right = exact(named_type_reference(parameter_type(
            make.parameters[1]
                .annotation
                .as_ref()
                .expect("module facade type"),
        )));
        assert_eq!(left, right);
        assert_eq!(left.module.source_library(), Some(origin));
        let ResolvedExprKind::Call { callee, .. } =
            &make.body.tail.as_deref().expect("constructor tail").kind
        else {
            panic!("constructor call remains explicit");
        };
        let constructor = exact(path_expression(callee));
        assert_eq!(constructor.module.source_library(), Some(origin));
        assert_eq!(
            resolved
                .entities
                .get(constructor)
                .and_then(|entity| entity.owner.as_ref())
                .map(|owner| owner.module.source_library()),
            Some(Some(origin))
        );

        let no_injection = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library("fn bad(value: Public) {}", vec![], vec![("actual", origin)]),
                ),
                (origin, library("pub struct Public {}", vec![], vec![])),
            ],
        ))
        .expect_err("a dependency alias does not inject the dependency namespace");
        assert!(matches!(
            no_injection.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Type,
                ref name,
            } if name == "Public"
        ));

        let child_alias = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "mod feature { use actual::Public; }",
                        vec![],
                        vec![("actual", origin)],
                    ),
                ),
                (origin, library("pub struct Public {}", vec![], vec![])),
            ],
        ))
        .expect_err("dependency aliases are not copied into child modules");
        assert!(matches!(
            child_alias.kind,
            ProjectDiagnosticKind::UnresolvedImport { ref path }
                if path == "actual::Public"
        ));

        for source in ["use api::actual::Public;", "use actual::Public;"] {
            let diagnostic = resolve_project(&graph(
                app,
                vec![
                    (app, library(source, vec![], vec![("api", facade)])),
                    (
                        facade,
                        library("fn facade() {}", vec![], vec![("actual", origin)]),
                    ),
                    (origin, library("pub struct Public {}", vec![], vec![])),
                ],
            ))
            .expect_err("private or absent transitive dependency aliases stay hidden");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::InaccessibleImport { .. }
                    | ProjectDiagnosticKind::UnresolvedImport { .. }
            ));
        }

        let private = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library("use actual::Private;", vec![], vec![("actual", origin)]),
                ),
                (origin, library("struct Private {}", vec![], vec![])),
            ],
        ))
        .expect_err("a direct edge does not expose a private declaration");
        assert!(matches!(
            private.kind,
            ProjectDiagnosticKind::InaccessibleImport { .. }
        ));

        let owner_gap = resolve_project(&graph(
            facade,
            vec![
                (
                    facade,
                    library(
                        "pub use actual::Choice::{One};",
                        vec![],
                        vec![("actual", origin)],
                    ),
                ),
                (
                    origin,
                    library("pub enum Choice { One(Int) }", vec![], vec![]),
                ),
            ],
        ))
        .expect_err("a constructor facade must also export its exact owner");
        assert!(matches!(
            owner_gap.kind,
            ProjectDiagnosticKind::MissingConstructorOwner { ref constructor }
                if constructor == "One"
        ));

        let alias_conflict = resolve_project(&graph(
            facade,
            vec![
                (
                    facade,
                    library("struct actual {}", vec![], vec![("actual", origin)]),
                ),
                (origin, library("fn origin() {}", vec![], vec![])),
            ],
        ))
        .expect_err("a dependency alias does not override a local Type binding");
        assert!(matches!(
            alias_conflict.kind,
            ProjectDiagnosticKind::NameConflict {
                namespace: NameNamespace::Type,
                ref name,
                ..
            } if name == "actual"
        ));
        assert_eq!(
            alias_conflict
                .primary
                .expect("the source side of the conflict is locatable")
                .library,
            facade
        );
    }

    #[test]
    fn private_intermediate_modules_remain_inaccessible_through_complete_import_paths() {
        for source in [
            "use outer::hidden::T; pub mod outer { mod hidden { pub struct T {} } }",
            "use outer::hidden::T as PrivateT; pub mod outer { mod hidden { pub struct T {} } }",
            "use outer::hidden::{T}; pub mod outer { mod hidden { pub struct T {} } }",
            "pub use outer::hidden::T; pub mod outer { mod hidden { pub struct T {} } }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("a private intermediate module blocks the complete import path");
            assert!(
                matches!(
                    diagnostic.kind,
                    ProjectDiagnosticKind::InaccessibleImport { ref path }
                        if path == "outer::hidden::T"
                ),
                "{source}: {diagnostic:?}"
            );
            let primary = diagnostic
                .primary
                .expect("the import has a real source origin");
            assert_eq!(primary.library, TEST_LIBRARY);
            assert_eq!(primary.source, SourceRef::Root);
        }

        let app = LibraryId(1);
        let dependency = LibraryId(2);
        for source in ["use dep::hidden::T;", "use dep::hidden::{T as PrivateT};"] {
            let diagnostic = resolve_project(&graph(
                app,
                vec![
                    (app, library(source, vec![], vec![("dep", dependency)])),
                    (
                        dependency,
                        library("mod hidden { pub struct T {} }", vec![], vec![]),
                    ),
                ],
            ))
            .expect_err("a dependency's private intermediate module blocks imports");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::InaccessibleImport { ref path }
                    if path == "dep::hidden::T"
            ));
            let primary = diagnostic
                .primary
                .expect("the consumer import has an origin");
            assert_eq!(primary.library, app);
            assert_eq!(primary.source, SourceRef::Root);
        }

        let missing = resolve_project(&project("use outer::missing::T; pub mod outer {}", vec![]))
            .expect_err("a genuinely missing path stays unresolved");
        assert!(matches!(
            missing.kind,
            ProjectDiagnosticKind::UnresolvedImport { ref path }
                if path == "outer::missing::T"
        ));

        resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use dep::T; fn accept(value: T) {}",
                        vec![],
                        vec![("dep", dependency)],
                    ),
                ),
                (
                    dependency,
                    library(
                        "pub use hidden::T; mod hidden { pub struct T {} }",
                        vec![],
                        vec![],
                    ),
                ),
            ],
        ))
        .expect("a public facade over a private module remains accessible");
    }

    #[test]
    fn equal_source_sites_in_different_libraries_never_share_identity_or_privacy() {
        let app = LibraryId(1);
        let first = LibraryId(2);
        let second = LibraryId(3);
        let same_source = "pub mod same { pub struct Item {} }";
        let resolved = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use first::same::Item as FirstItem; use second::same::Item as SecondItem; fn pair(left: FirstItem, right: SecondItem) {}",
                        vec![],
                        vec![("first", first), ("second", second)],
                    ),
                ),
                (first, library(same_source, vec![], vec![])),
                (second, library(same_source, vec![], vec![])),
            ],
        ))
        .expect("equal text and spans in two libraries remain distinct");
        let pair = function(module_body_in(&resolved, app, &[]), "pair");
        let first_item = exact(named_type_reference(parameter_type(
            pair.parameters[0]
                .annotation
                .as_ref()
                .expect("first item type"),
        )));
        let second_item = exact(named_type_reference(parameter_type(
            pair.parameters[1]
                .annotation
                .as_ref()
                .expect("second item type"),
        )));
        assert_ne!(first_item, second_item);
        assert_eq!(first_item.module, module_ref(first, &["same"]));
        assert_eq!(second_item.module, module_ref(second, &["same"]));
        assert_eq!(
            resolved
                .entities
                .get(first_item)
                .and_then(|entity| entity.declared_at.as_ref())
                .map(|origin| origin.library),
            Some(first)
        );
        assert_eq!(
            resolved
                .entities
                .get(second_item)
                .and_then(|entity| entity.declared_at.as_ref())
                .map(|origin| origin.library),
            Some(second)
        );

        let conflict = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use first::same::Item; use second::same::Item;",
                        vec![],
                        vec![("first", first), ("second", second)],
                    ),
                ),
                (first, library(same_source, vec![], vec![])),
                (second, library(same_source, vec![], vec![])),
            ],
        ))
        .expect_err("different source identities do not become a diamond delivery");
        assert!(matches!(
            conflict.kind,
            ProjectDiagnosticKind::NameConflict {
                namespace: NameNamespace::Type,
                ref name,
                ..
            } if name == "Item"
        ));

        let private = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use secret::deeper;",
                        vec![(
                            vec!["secret", "deeper"],
                            "use root::first::secret::hidden; fn local() { hidden() }",
                        )],
                        vec![("first", first)],
                    ),
                ),
                (
                    first,
                    library(
                        "use secret;",
                        vec![(vec!["secret"], "fn hidden() {}")],
                        vec![],
                    ),
                ),
            ],
        ))
        .expect_err("matching deeper paths in another library grant no private access");
        assert!(matches!(
            private.kind,
            ProjectDiagnosticKind::InaccessibleImport { ref path }
                if path == "root::first::secret::hidden"
        ));
        let primary = private.primary.expect("consumer import origin");
        assert_eq!(primary.library, app);
        assert_eq!(
            primary.source,
            SourceRef::File(FileModulePath::new(["secret", "deeper"]).unwrap())
        );
    }

    #[test]
    fn cross_library_references_keep_source_owners_and_checker_obligations_exact() {
        let app = LibraryId(1);
        let dependency = LibraryId(2);
        let resolved = resolve_project(&graph(
            app,
            vec![
                (
                    app,
                    library(
                        "use dep::original; fn wrapper(value: Int) -> Int { original(value) } fn deferred(value: dep::Packet::Item) {}",
                        vec![],
                        vec![("dep", dependency)],
                    ),
                ),
                (
                    dependency,
                    library(
                        "pub struct Packet { pub value: Int } impl Packet { pub fn keep(self: Self) -> Self { self } } pub fn choose<T>(value: T::Item) -> T::Item { value } pub fn original(value: Int) -> Int { value }",
                        vec![],
                        vec![],
                    ),
                ),
            ],
        ))
        .expect("source owners and deferred selections cross the library boundary");

        let dependency_root = module_body_in(&resolved, dependency, &[]);
        let choose = function(dependency_root, "choose");
        assert_eq!(
            choose.parameters[0]
                .binding
                .identity
                .module
                .source_library(),
            Some(dependency)
        );
        let ResolvedReference::Selection {
            occurrence,
            base,
            members,
            ..
        } = named_type_reference(parameter_type(
            choose.parameters[0]
                .annotation
                .as_ref()
                .expect("selected parameter type"),
        ))
        else {
            panic!("type-dependent member remains a Checker selection");
        };
        assert_eq!(occurrence.library, dependency);
        assert_eq!(base.kind, EntityKind::TypeParameter);
        assert_eq!(base.module.source_library(), Some(dependency));
        assert_eq!(
            base.owner
                .as_ref()
                .map(|owner| owner.module.source_library()),
            Some(Some(dependency))
        );
        assert_eq!(members[0].origin.library, dependency);
        assert!(members[0].declaration.is_none());

        let implementation = dependency_root
            .declarations
            .iter()
            .find_map(|declaration| match &declaration.kind {
                ResolvedDeclarationKind::InherentImpl(implementation) => Some(implementation),
                _ => None,
            })
            .expect("Packet implementation");
        let packet = exact(&implementation.target.reference);
        assert_eq!(packet.module.source_library(), Some(dependency));
        let ResolvedImplMemberKind::Function(keep) = &implementation.members[0].kind else {
            panic!("keep is a resolved method");
        };
        let ResolvedReference::Exact {
            target: self_identity,
            self_reference: Some(self_reference),
            ..
        } = named_type_reference(actual_return_type(
            keep.return_type.as_ref().expect("Self return type"),
        ))
        else {
            panic!("Self keeps both its binder and exact impl target");
        };
        assert_eq!(self_identity.module.source_library(), Some(dependency));
        assert_eq!(
            self_reference.identity.module.source_library(),
            Some(dependency)
        );
        assert_eq!(
            exact(
                &self_reference
                    .target
                    .as_deref()
                    .expect("Self target")
                    .reference
            ),
            packet
        );

        let app_root = module_body_in(&resolved, app, &[]);
        let wrapper_declaration = app_root
            .declarations
            .iter()
            .find(|declaration| {
                declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == "wrapper")
            })
            .expect("wrapper declaration");
        let wrapper_identity = wrapper_declaration
            .identity
            .as_ref()
            .expect("wrapper identity");
        let wrapper = function(app_root, "wrapper");
        let ResolvedExprKind::Call { callee, .. } =
            &wrapper.body.tail.as_deref().expect("wrapper call").kind
        else {
            panic!("wrapper tail is a call");
        };
        let original = exact(path_expression(callee));
        assert_eq!(wrapper_identity.module.source_library(), Some(app));
        assert_eq!(original.module.source_library(), Some(dependency));
        assert_ne!(wrapper_identity, original);
        let language_int = exact(named_type_reference(parameter_type(
            wrapper.parameters[0]
                .annotation
                .as_ref()
                .expect("wrapper parameter type"),
        )));
        assert!(language_int.module.is_language());

        let deferred = function(app_root, "deferred");
        let ResolvedReference::Selection {
            occurrence,
            base,
            members,
            ..
        } = named_type_reference(parameter_type(
            deferred.parameters[0]
                .annotation
                .as_ref()
                .expect("cross-library selected type"),
        ))
        else {
            panic!("cross-library associated item remains a Checker selection");
        };
        assert_eq!(occurrence.library, app);
        assert_eq!(base.module.source_library(), Some(dependency));
        assert_eq!(base.name, "Packet");
        assert_eq!(members[0].origin.library, app);
        assert!(members[0].declaration.is_none());
    }

    #[test]
    fn source_failures_follow_global_stage_and_library_order() {
        let first = LibraryId(1);
        let second = LibraryId(2);

        let frontend = resolve_project(&project_with_reachable_libraries(vec![
            (
                first,
                library(
                    "generate pending {} mod clash {}",
                    vec![(vec!["clash"], "")],
                    vec![],
                ),
            ),
            (second, library("@bad", vec![], vec![])),
        ]))
        .expect_err("frontend runs for every reachable root before later stages");
        assert!(matches!(frontend.kind, ProjectDiagnosticKind::Frontend(_)));
        assert_eq!(frontend.primary.expect("frontend origin").library, second);

        let module_graph = resolve_project(&project_with_reachable_libraries(vec![
            (
                first,
                library("mod clash {}", vec![(vec!["clash"], "")], vec![]),
            ),
            (second, library("generate pending {}", vec![], vec![])),
        ]))
        .expect_err("module graph runs globally before generation support");
        assert!(matches!(
            module_graph.kind,
            ProjectDiagnosticKind::ModuleBodyConflict { .. }
        ));
        assert_eq!(module_graph.primary.expect("module origin").library, first);

        let generation = resolve_project(&project_with_reachable_libraries(vec![
            (first, library("fn bad() { missing }", vec![], vec![])),
            (second, library("generate pending {}", vec![], vec![])),
        ]))
        .expect_err("generation support is checked before declaration and body names");
        assert_eq!(generation.kind, ProjectDiagnosticKind::GenerateUnsupported);
        assert_eq!(generation.primary.expect("generate origin").library, second);

        let declaration = resolve_project(&project_with_reachable_libraries(vec![
            (
                first,
                library("fn duplicate() {} fn duplicate() {}", vec![], vec![]),
            ),
            (second, library("use missing;", vec![], vec![])),
        ]))
        .expect_err("declaration indexing precedes imports in every library");
        assert!(matches!(
            declaration.kind,
            ProjectDiagnosticKind::NameConflict { ref name, .. }
                if name == "duplicate"
        ));
        assert_eq!(
            declaration.primary.expect("declaration origin").library,
            first
        );

        let import = resolve_project(&project_with_reachable_libraries(vec![
            (first, library("fn bad() { missing }", vec![], vec![])),
            (second, library("use absent;", vec![], vec![])),
        ]))
        .expect_err("import/export precedes body-name resolution globally");
        assert!(matches!(
            import.kind,
            ProjectDiagnosticKind::ImportCycle { ref path }
                if path == "absent"
        ));
        assert_eq!(import.primary.expect("import origin").library, second);

        let low_source = "// λ\nfn low() { missing_low }";
        let inputs = vec![
            (
                second,
                library("fn high() { missing_high }", vec![], vec![]),
            ),
            (first, library(low_source, vec![], vec![])),
        ];
        let forward = resolve_project(&project_with_reachable_libraries(inputs.clone()))
            .expect_err("the lower LibraryId owns the first body-name failure");
        let reverse = resolve_project(&project_with_reachable_libraries(
            inputs.into_iter().rev().collect(),
        ))
        .expect_err("library map construction order is irrelevant");
        assert_eq!(forward, reverse);
        let primary = forward.primary.expect("body-name origin");
        assert_eq!(primary.library, first);
        assert_eq!(primary.source, SourceRef::Root);
        assert_eq!(
            primary.span.start,
            low_source
                .find("missing_low")
                .expect("missing name byte offset")
        );

        let reachable_generate = resolve_project(&graph(
            TEST_LIBRARY,
            vec![
                (
                    TEST_LIBRARY,
                    library("fn main() {}", vec![], vec![("dep", second)]),
                ),
                (first, library("generate unreachable {}", vec![], vec![])),
                (second, library("generate reachable {}", vec![], vec![])),
            ],
        ))
        .expect_err("a reachable dependency root is scanned even when its alias is unused");
        assert_eq!(
            reachable_generate.kind,
            ProjectDiagnosticKind::GenerateUnsupported
        );
        assert_eq!(
            reachable_generate
                .primary
                .expect("reachable generate origin")
                .library,
            second
        );
    }

    #[test]
    fn resolves_owned_core_language_generic_and_sequential_bindings() {
        let mut sources = project(
            r#"
fn choose<T: Eq>(value: T) -> Option<T> {
    let old = value;
    let value = old;
    Option::Some(value)
}
"#,
            vec![],
        );
        let resolved = resolve_project(&sources).expect("project resolves");
        sources
            .libraries
            .get_mut(&TEST_LIBRARY)
            .expect("test library")
            .root
            .clear();
        assert_eq!(resolved, resolved.clone());

        let function = function(module_body(&resolved, &[]), "choose");
        let parameter = &function.parameters[0].binding.identity;
        let first = &function.body.statements[0];
        let second = &function.body.statements[1];
        let ResolvedStatementKind::Let {
            bindings: first_bindings,
            value: first_value,
            ..
        } = &first.kind
        else {
            panic!("first statement is let");
        };
        let ResolvedStatementKind::Let {
            bindings: second_bindings,
            value: second_value,
            ..
        } = &second.kind
        else {
            panic!("second statement is let");
        };
        assert_eq!(exact(path_expression(first_value)), parameter);
        assert_eq!(
            exact(path_expression(second_value)),
            &first_bindings[0].identity
        );
        assert_ne!(first_bindings[0].identity, second_bindings[0].identity);
        let tail = function.body.tail.as_deref().expect("tail expression");
        let ResolvedExprKind::Call { callee, arguments } = &tail.kind else {
            panic!("tail is constructor call");
        };
        assert_eq!(
            exact(path_expression(callee)).kind,
            EntityKind::EnumConstructor
        );
        assert_eq!(
            exact(path_expression(callee)).module.source_library(),
            Some(TEST_CORE)
        );
        let ResolvedCallArgument::Expression(argument) = &arguments[0] else {
            panic!("ordinary argument");
        };
        assert_eq!(
            exact(path_expression(argument)),
            &second_bindings[0].identity
        );
    }

    #[test]
    fn parses_only_sources_reached_by_use() {
        let sources = project(
            "use api; fn main() -> Int { api::answer() }",
            vec![
                ((vec!["api"]), "pub fn answer() -> Int { 42 }"),
                ((vec!["unused"]), "@not_vorton"),
            ],
        );
        let resolved = resolve_project(&sources).expect("unreachable bad source is ignored");
        assert!(module_body(&resolved, &["api"]).declarations.len() == 1);
        assert!(
            resolved
                .modules
                .get(&module_ref(TEST_LIBRARY, &["unused"]))
                .is_some_and(|module| module.body.is_none())
        );

        let diagnostic = resolve_project(&project("use bad;", vec![(vec!["bad"], "@not_vorton")]))
            .expect_err("reachable bad source fails");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::Frontend(_)
        ));
        assert_eq!(
            diagnostic.primary.expect("source origin").source,
            SourceRef::File(FileModulePath::new(["bad"]).unwrap())
        );

        let diagnostic = resolve_project(&project(
            "use api; fn api() {}",
            vec![(vec!["api"], "@not_vorton")],
        ))
        .expect_err("a touched module candidate is parsed before import ambiguity");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::Frontend(_)
        ));
        assert_eq!(
            diagnostic.primary.expect("candidate source origin").source,
            SourceRef::File(FileModulePath::new(["api"]).unwrap())
        );
    }

    #[test]
    fn combines_file_inline_and_synthetic_modules_with_modern_paths() {
        let sources = project(
            r#"
use tree::leaf::read;
pub fn root_value() -> Int { 1 }
fn main() -> Int { read() }
"#,
            vec![
                (
                    vec!["tree"],
                    r#"
use root::root_value;
pub fn helper() -> Int { root_value() }
pub mod inline { pub fn plus() -> Int { super::helper() } }
"#,
                ),
                (
                    vec!["tree", "leaf"],
                    r#"
use super::helper;
use super::inline::plus;
pub fn local() -> Int { 1 }
pub fn read() -> Int { self::local() + helper() + plus() }
"#,
                ),
            ],
        );
        let resolved = resolve_project(&sources).expect("mixed logical module tree resolves");
        for path in [vec!["tree"], vec!["tree", "leaf"], vec!["tree", "inline"]] {
            assert!(!module_body(&resolved, &path).declarations.is_empty());
        }

        let diagnostic = resolve_project(&project("use super::missing;", vec![]))
            .expect_err("a relative path cannot escape the anonymous root");
        assert_eq!(diagnostic.kind, ProjectDiagnosticKind::PathEscapesRoot);
    }

    #[test]
    fn rejects_file_inline_body_collision_even_when_file_is_otherwise_unreached() {
        let diagnostic = resolve_project(&project(
            "mod same {}",
            vec![(vec!["same"], "fn hidden() {}")],
        ))
        .expect_err("one logical path cannot have two bodies");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ModuleBodyConflict { ref module }
                if module == &vec!["same".to_owned()]
        ));

        let diagnostic = resolve_project(&project(
            "mod z { mod dup {} mod dup {} } mod a { mod dup {} mod dup {} }",
            vec![],
        ))
        .expect_err("module-graph conflicts use logical path order");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ModuleBodyConflict { ref module }
                if module == &vec!["a".to_owned(), "dup".to_owned()]
        ));
    }

    #[test]
    fn module_import_binds_only_the_module_and_supports_aliases() {
        let shadowed = resolve_project(&project(
            "mod tools { pub fn run() {} } fn test(tools: Int) { tools::run() }",
            vec![],
        ))
        .expect("non-container local Value does not hide a qualified module prefix");
        let test = function(module_body(&shadowed, &[]), "test");
        let tail = test.body.tail.as_deref().expect("qualified call tail");
        let ResolvedExprKind::Call { callee, .. } = &tail.kind else {
            panic!("qualified module member is called");
        };
        assert_eq!(
            exact(path_expression(callee)).module,
            module_ref(TEST_LIBRARY, &["tools"])
        );

        resolve_project(&project(
            "use lib as library; fn main() -> Int { library::item() }",
            vec![(vec!["lib"], "pub fn item() -> Int { 1 }")],
        ))
        .expect("module alias resolves");
        resolve_project(&project(
            "use tree as t; use t::leaf::item; fn main() -> Int { item() }",
            vec![
                (vec!["tree"], ""),
                (vec!["tree", "leaf"], "pub fn item() -> Int { 1 }"),
            ],
        ))
        .expect("module alias can make a nested file source reachable");

        let diagnostic = resolve_project(&project(
            "use lib; fn main() -> Int { item() }",
            vec![(vec!["lib"], "pub fn item() -> Int { 1 }")],
        ))
        .expect_err("module import does not import all members");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Value,
                ref name
            } if name == "item"
        ));
    }

    #[test]
    fn rejects_cross_namespace_import_ambiguity() {
        let diagnostic = resolve_project(&project(
            "use names::Same;",
            vec![(vec!["names"], "pub struct Same {} pub fn Same() {}")],
        ))
        .expect_err("one use item cannot import multiple namespaces");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousImport { .. }
        ));
    }

    #[test]
    fn same_origin_diamond_is_idempotent_but_different_origins_conflict() {
        let resolved = resolve_project(&project(
            "use left::item; use right::item; fn main() -> Int { item() }",
            vec![
                (vec!["leaf"], "pub fn item() -> Int { 1 }"),
                (vec!["left"], "pub use root::leaf::item;"),
                (vec!["right"], "pub use root::leaf::item;"),
            ],
        ))
        .expect("same exact declaration delivered twice is one binding");
        let root_values = resolved
            .entities
            .keys()
            .filter(|entity| entity.name == "item" && entity.kind == EntityKind::Function)
            .collect::<Vec<_>>();
        assert_eq!(root_values.len(), 1);

        let diagnostic = resolve_project(&project(
            "use left::item; use right::item; use missing;",
            vec![
                (vec!["left"], "pub fn item() -> Int { 1 }"),
                (vec!["right"], "pub fn item() -> Int { 2 }"),
            ],
        ))
        .expect_err("different declarations do not merge by leaf name");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::NameConflict {
                namespace: NameNamespace::Value,
                ref name,
                ..
            } if name == "item"
        ));
    }

    #[test]
    fn resolves_real_module_cycles_and_rejects_originless_forwarding_cycles() {
        resolve_project(&project(
            "use a::call_a; fn main() -> Int { call_a() }",
            vec![
                (
                    vec!["a"],
                    "use root::b::call_b; pub fn call_a() -> Int { call_b() }",
                ),
                (
                    vec!["b"],
                    "use root::a::call_a; pub fn call_b() -> Int { call_a() }",
                ),
            ],
        ))
        .expect("module back-edges with real declarations resolve");

        let diagnostic = resolve_project(&project(
            "use a::missing;",
            vec![
                (vec!["a"], "pub use root::b::missing;"),
                (vec!["b"], "pub use root::a::missing;"),
            ],
        ))
        .expect_err("forwarding cycle without a declaration has no origin");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ImportCycle { .. }
        ));
    }

    #[test]
    fn enforces_private_reexports_and_allows_private_module_facades() {
        resolve_project(&project(
            "use facade::visible; fn main() -> Int { visible() }",
            vec![(
                vec!["facade"],
                "pub use hidden::visible; mod hidden { pub fn visible() -> Int { 1 } }",
            )],
        ))
        .expect("facade can expose a public item from its private module");

        let diagnostic = resolve_project(&project(
            "use facade;",
            vec![(vec!["facade"], "pub use private; fn private() -> Int { 1 }")],
        ))
        .expect_err("re-export cannot make a private item public");
        assert!(
            matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::PrivateReExport { .. }
            ),
            "{diagnostic:?}"
        );
    }

    #[test]
    fn constructor_import_is_explicit_and_public_export_keeps_owner_closure() {
        let modules = vec![
            (vec!["leaf"], "pub enum Shape { Circle, Rect(Int) }"),
            (
                vec!["facade"],
                "pub use root::leaf::Shape; pub use root::leaf::Shape::{Circle};",
            ),
        ];
        resolve_project(&project(
            "use facade::{Shape, Circle}; fn main() { match Circle { Circle => (), _ => (), } }",
            modules.clone(),
        ))
        .expect("owner and explicitly imported constructor resolve");

        let diagnostic = resolve_project(&project(
            "use facade;",
            vec![
                (vec!["leaf"], "pub enum Shape { Circle, Rect(Int) }"),
                (vec!["facade"], "pub use root::leaf::Shape::{Circle};"),
            ],
        ))
        .expect_err("public constructor export requires exact owner export");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingConstructorOwner { .. }
        ));

        let diagnostic = resolve_project(&project(
            "use facade::Circle;",
            vec![
                (vec!["leaf"], "pub enum Shape { Circle }"),
                (vec!["facade"], "pub use root::leaf::Shape;"),
            ],
        ))
        .expect_err("re-exporting enum alone does not inject constructors");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedImport { .. }
        ));
    }

    #[test]
    fn core_constructors_require_explicit_import_and_keep_source_owners() {
        let resolved = resolve_project(&project(
            r#"
use test_core::Option as Maybe;
use Maybe::{Some, None};
use Ordering::Less;
fn make(value: Int) -> Maybe<Int> {
    match None { None => Some(value), _ => Some(value), }
}
fn first() -> Ordering { Less }
"#,
            vec![],
        ))
        .expect("explicit core constructor imports resolve");
        let constructors = resolved
            .entities
            .iter()
            .filter(|(identity, entity)| {
                identity.kind == EntityKind::EnumConstructor
                    && identity.module.source_library() == Some(TEST_CORE)
                    && entity
                        .owner
                        .as_ref()
                        .is_some_and(|owner| owner.name == "Option")
            })
            .collect::<Vec<_>>();
        assert_eq!(constructors.len(), 2);
        assert!(constructors.iter().all(|(_, constructor)| {
            constructor
                .owner
                .as_ref()
                .is_some_and(|owner| owner.name == "Option")
        }));
        let make = function(module_body(&resolved, &[]), "make");
        assert_eq!(
            exact(named_type_reference(actual_return_type(
                make.return_type.as_deref().expect("aliased Option return")
            ))),
            &resolved.core_roles.option.declaration
        );
        let first = function(module_body(&resolved, &[]), "first");
        assert_eq!(
            exact(path_expression(
                first
                    .body
                    .tail
                    .as_deref()
                    .expect("Ordering constructor tail")
            )),
            &resolved.core_roles.ordering.less
        );

        let diagnostic = resolve_project(&project(
            "fn make(value: Int) -> Option<Int> { Some(value) }",
            vec![],
        ))
        .expect_err("constructors are not in an implicit prelude");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "Some"
        ));
    }

    #[test]
    fn branch_bindings_do_not_escape_and_or_pattern_binders_share_identity() {
        let diagnostic = resolve_project(&project(
            r#"
fn leak(value: Option<Int>) {
    if let Option::Some(inner) = value { inner; }
    inner
}
"#,
            vec![],
        ))
        .expect_err("if-let binding is branch-local");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "inner"
        ));
        let diagnostic = resolve_project(&project(
            "fn leak_loop() { for item in [1] { item; } item }",
            vec![],
        ))
        .expect_err("for binding is loop-local");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "item"
        ));

        let resolved = resolve_project(&project(
            r#"
enum Choice { Left(Int), Right(Int) }
fn read(value: Choice) -> Int {
    match value { Choice::Left(item) | Choice::Right(item) => item, }
}
"#,
            vec![],
        ))
        .expect("or-pattern alternatives bind one logical value");
        let function = function(module_body(&resolved, &[]), "read");
        let tail = function.body.tail.as_deref().expect("match tail");
        let ResolvedExprKind::Match { arms, .. } = &tail.kind else {
            panic!("tail is match");
        };
        let ResolvedPatternKind::Or(alternatives) = &arms[0].pattern.kind else {
            panic!("arm retains or alternatives");
        };
        let binder = |pattern: &ResolvedPattern| {
            let ResolvedPatternKind::Constructor {
                fields: Some(ResolvedPatternFields::Positional(fields)),
                ..
            } = &pattern.kind
            else {
                panic!("constructor pattern");
            };
            let ResolvedPatternKind::Binding(binding) = &fields[0].kind else {
                panic!("payload binding");
            };
            binding.binding.identity.clone()
        };
        assert_eq!(binder(&alternatives[0]), binder(&alternatives[1]));

        let diagnostic = resolve_project(&project(
            "fn bad(value: Int) { match value { left | right => (), } }",
            vec![],
        ))
        .expect_err("or alternatives need the same binding set");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::PatternBindingMismatch
        );
    }

    #[test]
    fn qualified_constructor_patterns_require_exact_declarations() {
        for source in [
            "enum E { A } fn f(value: E) { match value { E::Missing => (), } }",
            "enum E { A(Int) } fn f(value: E) { match value { E::Missing(x) => x, } }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("constructor-shaped pattern cannot defer a missing constructor");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Value,
                    ref name,
                } if name == "Missing"
            ));
        }

        let diagnostic = resolve_project(&project(
            "struct Packet { value: Int } fn bad(packet: Packet) { match packet { Packet { value } => value, } }",
            vec![],
        ))
        .expect_err("pattern construction is reserved for exact enum constructors");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "Packet"
        ));
    }

    #[test]
    fn construct_roots_filter_namespaces_and_closed_fields_are_exact() {
        let resolved = resolve_project(&project(
            r#"
use Choice::Build;
enum Choice { Build { value: Int } }
struct Packet { value: Int }
fn from_constructor<Build>(value: Int) { Build { value } }
fn from_struct(Packet: Int) { Packet { value: 1 } }
"#,
            vec![],
        ))
        .expect("invalid candidates in one namespace do not hide a valid construct in another");
        for name in ["from_constructor", "from_struct"] {
            let tail = function(module_body(&resolved, &[]), name)
                .body
                .tail
                .as_deref()
                .expect("named construction tail");
            let ResolvedExprKind::NamedConstruct { target, entries } = &tail.kind else {
                panic!("expected named construction");
            };
            assert!(matches!(
                exact(target).kind,
                EntityKind::Struct | EntityKind::EnumConstructor
            ));
            let ResolvedConstructEntry::Field { member, .. } = &entries[0] else {
                panic!("expected named field");
            };
            assert_eq!(
                member
                    .declaration
                    .as_ref()
                    .expect("closed construct field is exact")
                    .kind,
                EntityKind::Field
            );
        }

        let diagnostic = resolve_project(&project(
            "struct Packet { value: Int } fn bad() { Packet { missing: 1 } }",
            vec![],
        ))
        .expect_err("a closed nominal field set cannot defer a missing member");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));

        let diagnostic = resolve_project(&project(
            "enum E { V { good: Int } } fn f(value: E) { match value { E::V { missing: Missing::Ctor } => (), } }",
            vec![],
        ))
        .expect_err("the earlier closed field error wins over its nested pattern error");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));
        assert_eq!(
            diagnostic.primary.expect("unknown field origin").span,
            Span::new(65, 72)
        );

        let diagnostic = resolve_project(&project(
            "use Choice::Build; enum Choice { Build { value: Int } } struct Build { value: Int } fn bad() { Build { value: 1 } }",
            vec![],
        ))
        .expect_err("two valid construct targets in different namespaces stay ambiguous");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousName { ref name } if name == "Build"
        ));

        let resolved = resolve_project(&project(
            "use Choice::Self; enum Choice { Self { value: Int } } fn value_self(value: Int) { Self { value } }",
            vec![],
        ))
        .expect("missing Type Self does not erase a legal Value constructor");
        let tail = function(module_body(&resolved, &[]), "value_self")
            .body
            .tail
            .as_deref()
            .expect("Value Self construction tail");
        let ResolvedExprKind::NamedConstruct { target, .. } = &tail.kind else {
            panic!("Value Self is a named constructor");
        };
        assert!(matches!(
            target,
            ResolvedReference::Exact {
                target,
                self_reference: None,
                ..
            } if target.kind == EntityKind::EnumConstructor && target.name == "Self"
        ));

        let diagnostic = resolve_project(&project(
            "use Choice::Self; enum Choice { Self { value: Int } } struct Owner { value: Int } impl Owner { fn make(value: Int) { Self { value } } }",
            vec![],
        ))
        .expect_err("Type Self and Value Self remain independent construct candidates");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousName { ref name } if name == "Self"
        ));
    }

    #[test]
    fn type_position_rejects_known_value_member() {
        for (source, expected_name) in [
            (
                "trait T { fn method(self: Self); } fn f(value: T::method) {}",
                "method",
            ),
            ("fn f(value: PartialEq::eq) {}", "eq"),
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("a known Value method is not a Type selection");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Type,
                    ref name,
                } if name == expected_name
            ));
        }

        let diagnostic = resolve_project(&project(
            "trait T { type Item; } fn f() { T::Item }",
            vec![],
        ))
        .expect_err("a known Type member is not a Value selection");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Value,
                ref name,
            } if name == "Item"
        ));
    }

    #[test]
    fn generic_self_and_capture_rules_resolve_without_type_selection() {
        for source in [
            "trait Rel<T> {} struct Foo {} impl Rel<Self> for Foo {}",
            "trait Rel<T> {} struct Foo<T> {} impl<T: Rel<Self>> Foo<Self> {}",
            "trait Rel<T> {} struct Foo<T: Rel<Self>> {}",
            "trait Rel<T> {} enum Foo<T: Rel<Self>> {}",
            "trait Rel<T> {} trait Foo<T: Rel<Self>> { fn keep<U: Rel<Self>>(value: Self); }",
        ] {
            resolve_project(&project(source, vec![]))
                .expect("impl Self covers trait signature, target, and generic bounds");
        }

        let resolved = resolve_project(&project(
            r#"
struct Boxed<T> { value: T }
impl<T: Eq> Boxed<T> {
    fn get(self: Self) -> T {
        let closure = fn [self]() -> T { self.value };
        closure()
    }
}
trait Identity<T> { fn identity(self: Self) -> T; }
"#,
            vec![],
        ))
        .expect("generic and owner Self scopes resolve");
        assert!(
            resolved
                .entities
                .keys()
                .any(|entity| entity.kind == EntityKind::SelfType)
        );
        let self_bindings = resolved
            .entities
            .keys()
            .filter(|entity| {
                entity.module.source_library() == Some(TEST_LIBRARY)
                    && entity.name == "self"
                    && entity.namespace == Namespace::Value
            })
            .collect::<Vec<_>>();
        assert_eq!(self_bindings.len(), 2, "method and trait parameters");
        assert!(
            self_bindings
                .iter()
                .all(|binding| binding.kind == EntityKind::Parameter),
            "capture occurrence must not create a source binder"
        );

        let diagnostic = resolve_project(&project(
            "fn bad<T: Eq>() { let closure = fn [missing]() { missing; }; }",
            vec![],
        ))
        .expect_err("explicit capture resolves in the outer value scope");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));

        let diagnostic = resolve_project(&project(
            "struct Boxed<T> { value: T } impl<T> Boxed<T> { fn bad<T>() {} }",
            vec![],
        ))
        .expect_err("member generic cannot shadow visible impl generic");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::DuplicateBinding { ref name } if name == "T"
        ));
    }

    #[test]
    fn self_qualified_paths_use_the_resolved_impl_target() {
        let resolved = resolve_project(&project(
            r#"
enum Choice { Ready }
impl Choice {
    fn read(value: Self) { match value { Self::Ready => (), } }
}
struct Packet { value: Int }
impl Packet {
    fn make(value: Int) -> Self { Self { value } }
}
trait Make { fn make(value: Int) -> Self; }
impl Make for Packet {
    fn make(value: Int) -> Self { Self { value } }
}
struct Boxed<T> { value: T }
impl<T> Boxed<T> {
    fn keep(value: Self) -> Self { value }
}
"#,
            vec![],
        ))
        .expect("impl Self paths reuse the resolved target identity");
        let root = module_body(&resolved, &[]);
        let mut packet_constructions = 0;
        for declaration in &root.declarations {
            let implementation = match &declaration.kind {
                ResolvedDeclarationKind::InherentImpl(implementation) => implementation,
                ResolvedDeclarationKind::TraitImpl { implementation, .. } => implementation,
                _ => continue,
            };
            let target = exact(&implementation.target.reference);
            assert!(matches!(
                implementation.target.reference,
                ResolvedReference::Exact {
                    self_reference: None,
                    ..
                }
            ));
            let ResolvedImplMemberKind::Function(function) = &implementation.members[0].kind else {
                panic!("test impl member is a function");
            };
            if target.name == "Choice" {
                let tail = function.body.tail.as_deref().expect("Choice match tail");
                let ResolvedExprKind::Match { arms, .. } = &tail.kind else {
                    panic!("Choice body is a match");
                };
                let ResolvedPatternKind::Constructor {
                    target: constructor,
                    ..
                } = &arms[0].pattern.kind
                else {
                    panic!("Self::Ready is a constructor pattern");
                };
                let ResolvedReference::Exact {
                    target: constructor,
                    self_reference: Some(self_reference),
                    ..
                } = constructor
                else {
                    panic!("Self::Ready retains Self and its resolved target");
                };
                assert_eq!(self_reference.identity.kind, EntityKind::SelfType);
                assert_eq!(
                    exact(
                        &self_reference
                            .target
                            .as_deref()
                            .expect("Self has a resolved Choice target")
                            .reference
                    ),
                    target
                );
                assert_eq!(constructor.name, "Ready");
                assert_eq!(
                    constructor.owner.as_ref().expect("constructor owner").name,
                    "Choice"
                );
            } else if target.name == "Packet" {
                packet_constructions += 1;
                let tail = function
                    .body
                    .tail
                    .as_deref()
                    .expect("Packet construct tail");
                let ResolvedExprKind::NamedConstruct {
                    target: constructed,
                    entries,
                } = &tail.kind
                else {
                    panic!("Self is a named construction");
                };
                let ResolvedReference::Exact {
                    target: constructed,
                    self_reference: Some(self_reference),
                    ..
                } = constructed
                else {
                    panic!("Self construction retains Self and its resolved target");
                };
                assert_eq!(constructed, target);
                assert_eq!(self_reference.identity.kind, EntityKind::SelfType);
                assert_eq!(
                    exact(
                        &self_reference
                            .target
                            .as_deref()
                            .expect("Self has a resolved Packet target")
                            .reference
                    ),
                    target
                );
                let return_type = function.return_type.as_ref().expect("Self return type");
                let ResolvedReference::Exact {
                    target: self_identity,
                    self_reference: Some(return_self),
                    ..
                } = named_type_reference(actual_return_type(return_type))
                else {
                    panic!("direct Self type retains its identity and target relation");
                };
                assert_eq!(self_identity.kind, EntityKind::SelfType);
                assert_eq!(&return_self.identity, self_identity);
                assert_eq!(
                    exact(
                        &return_self
                            .target
                            .as_deref()
                            .expect("return Self has a resolved target")
                            .reference
                    ),
                    target
                );
                let ResolvedConstructEntry::Field { member, .. } = &entries[0] else {
                    panic!("Packet construction has a field");
                };
                assert_eq!(
                    member
                        .declaration
                        .as_ref()
                        .expect("Self field is exact")
                        .kind,
                    EntityKind::Field
                );
            } else if target.name == "Boxed" {
                let return_type = function
                    .return_type
                    .as_ref()
                    .expect("generic Self return type");
                let ResolvedReference::Exact {
                    target: self_identity,
                    self_reference: Some(self_reference),
                    ..
                } = named_type_reference(actual_return_type(return_type))
                else {
                    panic!("generic Self retains its complete impl target");
                };
                assert_eq!(self_identity.kind, EntityKind::SelfType);
                let target = self_reference
                    .target
                    .as_deref()
                    .expect("generic Self has a resolved target");
                assert_eq!(exact(&target.reference).name, "Boxed");
                let ResolvedTypeArgument::Type(argument) = &target.arguments[0] else {
                    panic!("Boxed target keeps its type argument");
                };
                let parameter = exact(named_type_reference(argument));
                assert_eq!(parameter.kind, EntityKind::TypeParameter);
                assert_eq!(parameter.name, "T");
            }
        }
        assert_eq!(
            packet_constructions, 2,
            "inherent and trait impls both link Self"
        );
    }

    #[test]
    fn type_dependent_member_selection_keeps_exact_base_without_faking_target() {
        let resolved = resolve_project(&project(
            r#"
mod T { pub type Item = Int; }
trait HasItem { type Item; fn get(self: Self) -> Item; }
fn read<T: HasItem>(value: T) -> T::Item { value.get() }
fn shadow<T>(T: Int) { T::member }
struct Concrete {}
fn concrete(value: Concrete::Item) {}
fn language(value: Iterable::Item) {}
"#,
            vec![],
        ))
        .expect("type-dependent selection is a resolved carrier state");
        let root = module_body(&resolved, &[]);
        let trait_declaration = root
            .declarations
            .iter()
            .find(|declaration| {
                declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == "HasItem")
            })
            .expect("trait declaration");
        let ResolvedDeclarationKind::Trait { members, .. } = &trait_declaration.kind else {
            panic!("resolved trait");
        };
        let ResolvedTraitMemberKind::Method(signature) = &members[1].kind else {
            panic!("trait method");
        };
        let ResolvedTypeKind::Named(unqualified_item) = &signature
            .return_type
            .as_ref()
            .expect("trait method return")
            .kind
        else {
            panic!("unqualified associated type");
        };
        let ResolvedReference::Selection { members, .. } = &unqualified_item.reference else {
            panic!("unqualified associated item is still an explicit selection");
        };
        assert_eq!(
            members[0]
                .declaration
                .as_ref()
                .expect("exact associated declaration")
                .kind,
            EntityKind::AssociatedType
        );

        let read_function = function(root, "read");
        let return_type = read_function
            .return_type
            .as_ref()
            .expect("return annotation");
        let ResolvedTypeKind::Named(named) = &actual_return_type(return_type).kind else {
            panic!("named associated type");
        };
        let ResolvedReference::Selection { base, members, .. } = &named.reference else {
            panic!("associated type remains an explicit selection");
        };
        assert_eq!(base.kind, EntityKind::TypeParameter);
        assert_eq!(members[0].name, "Item");
        assert!(members[0].declaration.is_none());
        let tail = read_function
            .body
            .tail
            .as_deref()
            .expect("method call tail");
        let ResolvedExprKind::MethodCall { method, .. } = &tail.kind else {
            panic!("method call remains a member selection");
        };
        assert_eq!(method.name, "get");
        assert!(method.declaration.is_none());

        let shadow = function(root, "shadow");
        let ResolvedReference::Selection { base, .. } =
            path_expression(shadow.body.tail.as_deref().expect("selection tail"))
        else {
            panic!("generic remains the qualified selection base");
        };
        assert_eq!(base.kind, EntityKind::TypeParameter);

        let concrete = function(root, "concrete");
        let ResolvedTypeKind::Named(concrete_selection) = &parameter_type(
            concrete.parameters[0]
                .annotation
                .as_ref()
                .expect("concrete parameter type"),
        )
        .kind
        else {
            panic!("concrete associated selection is named");
        };
        let ResolvedReference::Selection { base, members, .. } = &concrete_selection.reference
        else {
            panic!("an incomplete impl/member table remains a Checker obligation");
        };
        assert_eq!(base.kind, EntityKind::Struct);
        assert_eq!(members[0].name, "Item");
        assert!(members[0].declaration.is_none());

        let core = function(root, "language");
        let ResolvedTypeKind::Named(core_selection) = &parameter_type(
            core.parameters[0]
                .annotation
                .as_ref()
                .expect("core associated type"),
        )
        .kind
        else {
            panic!("core associated selection is named");
        };
        let ResolvedReference::Selection { base, members, .. } = &core_selection.reference else {
            panic!("core associated type remains a selection");
        };
        assert_eq!(base.kind, EntityKind::Trait);
        assert_eq!(base.module.source_library(), Some(TEST_CORE));
        assert_eq!(base.name, "Iterable");
        assert_eq!(
            members[0]
                .declaration
                .as_ref()
                .expect("specified core member is exact")
                .kind,
            EntityKind::AssociatedType
        );

        let categorized = resolve_project(&project(
            r#"
enum E { V }
impl E { type V = Int; }
fn enum_member(value: E::V) {}
struct Box { Item: Int }
impl Box { type Item = Int; }
fn struct_member(value: Box::Item) {}
trait Parent { type Item; }
trait Child: Parent { fn Item(self: Self); }
fn inherited_member(value: Child::Item) {}
trait Outer {
    type Item;
    fn direct(value: Item::Nested);
    fn via_self(value: Self::Item::Nested);
}
"#,
            vec![],
        ))
        .expect("member categories are formed independently before selection");
        let categorized_root = module_body(&categorized, &[]);
        for (name, expected_base) in [
            ("enum_member", EntityKind::Enum),
            ("struct_member", EntityKind::Struct),
            ("inherited_member", EntityKind::Trait),
        ] {
            let annotation = function(categorized_root, name).parameters[0]
                .annotation
                .as_ref()
                .expect("categorized parameter annotation");
            let ResolvedReference::Selection {
                base,
                namespace,
                members,
                self_reference,
                ..
            } = named_type_reference(parameter_type(annotation))
            else {
                panic!("categorized member remains an explicit selection");
            };
            assert_eq!(*namespace, Namespace::Type);
            assert_eq!(base.kind, expected_base);
            assert_eq!(members.len(), 1);
            assert!(members[0].declaration.is_none());
            assert!(self_reference.is_none());
        }

        let outer = categorized_root
            .declarations
            .iter()
            .find(|declaration| {
                declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == "Outer")
            })
            .expect("Outer trait declaration");
        let ResolvedDeclarationKind::Trait { members, .. } = &outer.kind else {
            panic!("Outer is a resolved trait");
        };
        for member in &members[1..] {
            let ResolvedTraitMemberKind::Method(signature) = &member.kind else {
                panic!("Outer member is a method");
            };
            let annotation = signature.parameters[0]
                .annotation
                .as_ref()
                .expect("nested associated annotation");
            let ResolvedReference::Selection {
                base,
                namespace,
                members,
                self_reference,
                ..
            } = named_type_reference(parameter_type(annotation))
            else {
                panic!("nested associated path is a selection");
            };
            assert_eq!(base.name, "Outer");
            assert_eq!(*namespace, Namespace::Type);
            assert_eq!(members.len(), 2);
            assert_eq!(
                members[0]
                    .declaration
                    .as_ref()
                    .expect("Outer::Item is exact")
                    .kind,
                EntityKind::AssociatedType
            );
            assert_eq!(members[1].name, "Nested");
            assert!(members[1].declaration.is_none());
            if member.identity.name == "via_self" {
                let self_reference = self_reference
                    .as_deref()
                    .expect("Self::Item keeps its Self root identity");
                assert_eq!(self_reference.identity.kind, EntityKind::SelfType);
                assert_eq!(
                    self_reference
                        .identity
                        .owner
                        .as_ref()
                        .expect("Self keeps its trait owner")
                        .name,
                    "Outer"
                );
                assert!(self_reference.target.is_none());
            } else {
                assert!(self_reference.is_none());
            }
        }

        let diagnostic = resolve_project(&project(
            "trait Closed { fn V(self: Self); } fn take(value: Closed::V) {}",
            vec![],
        ))
        .expect_err("a closed wrong-category member cannot manufacture a Type candidate");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Type,
                ref name,
            } if name == "V"
        ));

        let diagnostic = resolve_project(&project("fn bad(value: PartialEq::Missing) {}", vec![]))
            .expect_err("a closed core trait cannot invent an associated item");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "Missing"
        ));

        let diagnostic = resolve_project(&project(
            "trait Source { type Item; } fn f<T: Source<Missing = Int>>(value: T) {}",
            vec![],
        ))
        .expect_err("a closed trait owner cannot defer an unknown associated binding");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Type,
                ref name,
            } if name == "Missing"
        ));
        assert_eq!(
            diagnostic
                .primary
                .expect("unknown associated binding origin")
                .span,
            Span::new(43, 50)
        );

        resolve_project(&project(
            "trait Parent { type Item; } trait Child: Parent {} fn keep<T: Child<Item = Int>>(value: T) {}",
            vec![],
        ))
        .expect("a supertrait member set stays pending until inherited selection is complete");
    }

    #[test]
    fn resolves_callable_effect_formals_method_schemes_and_implicit_positions() {
        let root = r#"
use api::Query;

fn run<T: Query, F: Fn + fn(Str) -> Unit with {E}, effect E, effect Tail>(
    source: T,
    callback: call F
) -> Unit with {Query::fetch<T, F, effect {E, fs}, effect {Tail}>} {
    source.fetch(callback)
}
"#;
        let defs = r#"
pub trait Fetch {
    fn fetch<U, F: Fn + fn(U) -> Unit with {Callback}, G: Fn + fn(Int) -> Unit, effect Callback, effect Extra>(
        self,
        callback: call F,
        nested: G
    ) -> Unit;
}
"#;
        let resolved = resolve_project(&project(
            root,
            vec![
                (vec!["api"], "pub use root::defs::Fetch as Query;"),
                (vec!["defs"], defs),
            ],
        ))
        .expect("callable effect identities resolve through a re-export alias");

        let defs_body = module_body(&resolved, &["defs"]);
        let ResolvedDeclarationKind::Trait { members, .. } = &defs_body.declarations[0].kind else {
            panic!("Fetch trait expected")
        };
        let ResolvedTraitMemberKind::Method(method) = &members[0].kind else {
            panic!("Fetch::fetch method expected")
        };
        assert_eq!(method.effect_parameters.len(), 2);
        for (parameter, name) in method.effect_parameters.iter().zip(["Callback", "Extra"]) {
            assert_eq!(parameter.binding.identity.kind, EntityKind::EffectParameter);
            assert_eq!(parameter.binding.identity.namespace, Namespace::Effect);
            assert_eq!(parameter.binding.identity.name, name);
            assert_eq!(
                parameter
                    .binding
                    .identity
                    .owner
                    .as_ref()
                    .expect("effect formal has its method owner")
                    .name,
                "fetch"
            );
        }
        let ResolvedGenericBound::Named(callable_trait) = &method.type_parameters[1].bounds[0]
        else {
            panic!("F starts with its callable trait bound")
        };
        assert_eq!(exact(&callable_trait.reference).name, "Fn");
        let ResolvedGenericBound::Shape(callback_shape) = &method.type_parameters[1].bounds[1]
        else {
            panic!("F retains its callable shape bound")
        };
        let ResolvedShapeKind::Callable {
            effects: Some(callback_effects),
            ..
        } = &callback_shape.kind
        else {
            panic!("callback shape with an effect row expected")
        };
        assert_eq!(
            exact(&callback_effects.effects[0].reference),
            &method.effect_parameters[0].binding.identity
        );

        let callback = method.parameters[1]
            .annotation
            .as_ref()
            .expect("callback type is present");
        let call_start =
            defs.find("callback: call").expect("call mode source") + "callback: ".len();
        assert_eq!(
            method.parameters[1].mode,
            Some((Span::new(call_start, call_start + 4), ParameterMode::Call))
        );
        assert_eq!(
            exact(named_type_reference(parameter_type(callback))).name,
            "F"
        );
        let nested = method.parameters[2]
            .annotation
            .as_ref()
            .expect("nested callback type is present");
        assert_eq!(
            exact(named_type_reference(parameter_type(nested))).name,
            "G"
        );

        let run = function(module_body(&resolved, &[]), "run");
        assert_eq!(run.type_parameters.len(), 2);
        assert_eq!(run.effect_parameters.len(), 2);
        let scheme = &run
            .effects
            .as_ref()
            .expect("run has a method scheme bound")
            .effects[0];
        let target = exact(&scheme.reference);
        assert_eq!(target, &members[0].identity);
        assert_eq!(target.kind, EntityKind::Method);
        assert_eq!(
            target
                .owner
                .as_ref()
                .expect("method keeps the exact trait owner")
                .name,
            "Fetch"
        );
        assert_eq!(scheme.arguments.len(), 2);
        assert_eq!(
            exact(named_type_reference(&scheme.arguments[0])),
            &run.type_parameters[0].binding.identity
        );
        assert_eq!(scheme.effect_arguments.len(), 2);
        let first_row = &scheme.effect_arguments[0].effects;
        assert_eq!(first_row.effects.len(), 2);
        assert_eq!(
            exact(&first_row.effects[0].reference),
            &run.effect_parameters[0].binding.identity
        );
        assert_eq!(
            exact(&first_row.effects[1].reference).kind,
            EntityKind::LanguageEffect
        );
        assert_eq!(
            exact(&scheme.effect_arguments[1].effects.effects[0].reference),
            &run.effect_parameters[1].binding.identity
        );
    }

    #[test]
    fn transports_const_shapes_modes_where_and_qualified_bindings() {
        let source = r#"
trait Contract {}
struct Target<T> { value: T }
impl<T, G: Fn, F: Fn + fn(scoped &T, call G) -> T with {mut}> Contract for Target<T>
where (T, T): Eq + Debug, T::Item: Eq, {
    const fn run(
        callback: scoped call F,
        state: &mut T,
        owned: move T,
        direct: fn(&T) -> T,
    ) -> (fn(call G) -> T with {mut}) with {mut} {
        match state { mut value | move value => value }
    }
}
"#;
        let resolved = resolve_project(&project(source, vec![]))
            .expect("new frontend carriers should resolve without semantic selection");
        let root = module_body(&resolved, &[]);
        let ResolvedDeclarationKind::TraitImpl {
            implementation,
            where_clause: Some(where_clause),
            ..
        } = &root.declarations[2].kind
        else {
            panic!("trait implementation expected")
        };
        assert_eq!(where_clause.predicates.len(), 2);
        assert_eq!(
            &source[where_clause.keyword_span.start..where_clause.keyword_span.end],
            "where"
        );
        assert!(matches!(
            where_clause.predicates[0].subject.kind,
            ResolvedTypeKind::Tuple(ref elements) if elements.len() == 2
        ));
        assert_eq!(where_clause.predicates[0].bounds.len(), 2);

        let ResolvedGenericBound::Shape(shape) = &implementation.type_parameters[2].bounds[1]
        else {
            panic!("F callable shape bound expected")
        };
        let ResolvedShapeKind::Callable {
            parameters,
            effects: Some(effects),
            ..
        } = &shape.kind
        else {
            panic!("callable shape carrier expected")
        };
        let scoped_start = source.find("scoped &T").expect("scoped shape parameter");
        assert_eq!(
            parameters[0].escape,
            Some(Span::new(scoped_start, scoped_start + "scoped".len()))
        );
        assert_eq!(
            parameters[0].mode.as_ref().unwrap().1,
            ParameterMode::Borrow
        );
        assert_eq!(parameters[1].mode.as_ref().unwrap().1, ParameterMode::Call);
        assert!(effects.effects[0].arguments.is_empty());
        assert_eq!(exact(&effects.effects[0].reference).name, "mut");

        let ResolvedImplMemberKind::Function(method) = &implementation.members[0].kind else {
            panic!("const impl method expected")
        };
        let const_span = method.const_span.expect("const span");
        assert_eq!(&source[const_span.start..const_span.end], "const");
        assert!(method.parameters[0].escape.is_some());
        assert_eq!(
            method.parameters[0].mode.as_ref().unwrap().1,
            ParameterMode::Call
        );
        assert_eq!(
            method.parameters[1].mode.as_ref().unwrap().1,
            ParameterMode::MutBorrow
        );
        assert_eq!(
            method.parameters[2].mode.as_ref().unwrap().1,
            ParameterMode::Move
        );
        assert!(matches!(
            method.parameters[3].annotation,
            Some(ResolvedParameterAnnotation::Shape(_))
        ));
        let Some(ResolvedReturnAnnotation::Shape(factory)) = method.return_type.as_deref() else {
            panic!("factory return shape expected")
        };
        let ResolvedShapeKind::Grouped(factory) = &factory.kind else {
            panic!("factory grouping expected")
        };
        assert!(matches!(factory.kind, ResolvedShapeKind::Callable { .. }));

        let match_tail = method.body.tail.as_deref().expect("match tail");
        let ResolvedExprKind::Match { arms, .. } = &match_tail.kind else {
            panic!("match expression expected")
        };
        let ResolvedPatternKind::Or(alternatives) = &arms[0].pattern.kind else {
            panic!("or pattern expected")
        };
        let qualifiers = alternatives
            .iter()
            .map(|alternative| {
                let ResolvedPatternKind::Binding(binding) = &alternative.kind else {
                    panic!("qualified binding expected")
                };
                binding.qualifier.expect("qualifier").1
            })
            .collect::<Vec<_>>();
        assert_eq!(qualifiers, [BindingMode::Mut, BindingMode::Move]);
        let first = match &alternatives[0].kind {
            ResolvedPatternKind::Binding(binding) => &binding.binding.identity,
            _ => unreachable!(),
        };
        let second = match &alternatives[1].kind {
            ResolvedPatternKind::Binding(binding) => &binding.binding.identity,
            _ => unreachable!(),
        };
        assert_eq!(
            first, second,
            "or alternatives keep one logical binding identity"
        );
    }

    #[test]
    fn callable_generic_diagnostics_follow_source_order_after_effect_prescan() {
        let body_source = "fn f<T: Missing, effect E, effect E>() {}";
        let body_diagnostic = resolve_project(&project(body_source, vec![]))
            .expect_err("the earlier missing type bound wins over a later effect duplicate");
        assert!(matches!(
            body_diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Type,
                ref name,
            } if name == "Missing"
        ));
        assert_eq!(
            body_diagnostic
                .primary
                .expect("the missing type bound has an origin")
                .span,
            Span::new(8, 15)
        );

        let signature_source = "trait Api { fn f<T: Missing, effect E, effect E>(); }";
        let signature_diagnostic = resolve_project(&project(signature_source, vec![]))
            .expect_err("signature generic diagnostics use the same source ordering");
        assert!(matches!(
            signature_diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Type,
                ref name,
            } if name == "Missing"
        ));
        let missing_start = signature_source.find("Missing").expect("bound spelling");
        assert_eq!(
            signature_diagnostic
                .primary
                .expect("the signature bound has an origin")
                .span,
            Span::new(missing_start, missing_start + "Missing".len())
        );

        resolve_project(&project(
            "fn f<T: Fn + fn() -> Unit with {E}, effect E>(callback: call T) {}",
            vec![],
        ))
        .expect("type bounds can still reference a later effect formal");
    }

    #[test]
    fn rejects_effect_kind_and_method_scheme_name_boundaries() {
        for (source, namespace, expected_name) in [
            (
                "fn bad<T>() -> Unit with {T} {}",
                NameNamespace::Effect,
                "T",
            ),
            ("fn bad<effect E>(value: E) {}", NameNamespace::Type, "E"),
            (
                "trait Fetch { fn fetch(self); } fn bad<T>() with {T::fetch<T>} {}",
                NameNamespace::Effect,
                "fetch",
            ),
            (
                "trait Fetch { fn fetch(self); } fn bad() with {Fetch::missing<Int>} {}",
                NameNamespace::Effect,
                "missing",
            ),
            (
                "use Fetch::fetch; trait Fetch { fn fetch(self); } fn bad() with {fetch<Int>} {}",
                NameNamespace::Effect,
                "fetch",
            ),
            (
                "effect Reader<T> {} fn bad<effect E>() with {Reader<Int, effect {E}>} {}",
                NameNamespace::Effect,
                "Reader",
            ),
            (
                "fn bad<effect E>() with {E<Int>} {}",
                NameNamespace::Effect,
                "E",
            ),
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("invalid type/effect or method identity must be rejected");
            assert!(
                matches!(
                    diagnostic.kind,
                    ProjectDiagnosticKind::UnresolvedName {
                        namespace: actual_namespace,
                        ref name,
                    } if actual_namespace == namespace && name == expected_name
                ),
                "{source}: {diagnostic:?}"
            );
        }

        let duplicate = resolve_project(&project("fn bad<effect E, effect E>() {}", vec![]))
            .expect_err("duplicate effect formals are rejected");
        assert!(matches!(
            duplicate.kind,
            ProjectDiagnosticKind::DuplicateBinding { ref name } if name == "E"
        ));

        let reserved = resolve_project(&project("fn bad<effect fs>() {}", vec![]))
            .expect_err("language effects cannot be shadowed by formals");
        assert!(matches!(
            reserved.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding {
                namespace: NameNamespace::Effect,
                ref name,
                ..
            } if name == "fs"
        ));
    }

    #[test]
    fn effect_operation_receiver_is_exact_and_cross_namespace_ambiguity_is_rejected() {
        let resolved = resolve_project(&project(
            r#"
effect Logger { fn log(value: Int) -> Unit; }
fn write() -> Unit with {Logger} { Logger.log(1) }
"#,
            vec![],
        ))
        .expect("custom effect operation resolves through the method surface");
        let write_function = function(module_body(&resolved, &[]), "write");
        let tail = write_function
            .body
            .tail
            .as_deref()
            .expect("effect call tail");
        let ResolvedExprKind::MethodCall {
            receiver, method, ..
        } = &tail.kind
        else {
            panic!("effect operation is a method-shaped call");
        };
        let ResolvedExprKind::Path(receiver) = &receiver.kind else {
            panic!("effect receiver retains its exact path");
        };
        assert_eq!(exact(receiver).kind, EntityKind::Effect);
        assert_eq!(
            method
                .declaration
                .as_ref()
                .expect("known custom operation declaration")
                .kind,
            EntityKind::EffectOperation
        );

        let resolved = resolve_project(&project(
            "fn raise(error: Int) { fail.raise(error) }",
            vec![],
        ))
        .expect("the specified Language failure operation has exact identity");
        let tail = function(module_body(&resolved, &[]), "raise")
            .body
            .tail
            .as_deref()
            .expect("failure call tail");
        let ResolvedExprKind::MethodCall { method, .. } = &tail.kind else {
            panic!("failure operation is method-shaped");
        };
        let raise = method
            .declaration
            .as_ref()
            .expect("fail.raise is an exact Language member");
        assert!(raise.module.is_language());
        assert_eq!(raise.kind, EntityKind::EffectOperation);

        let diagnostic = resolve_project(&project(
            r#"
effect Source { fn read() -> Int; }
fn Source() -> Int { 1 }
fn ambiguous() -> Int { Source.read() }
"#,
            vec![],
        ))
        .expect_err("effect and value receivers have no namespace priority");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousName { ref name } if name == "Source"
        ));

        resolve_project(&project(
            "effect Source {} fn Source() -> Int { 1 } fn selected() { Source.missing() } fn local(console: Int) { console.missing() }",
            vec![],
        ))
        .expect("an Effect without the requested operation does not steal a Value receiver");

        let diagnostic = resolve_project(&project(
            "effect Empty {} fn bad() { Empty.missing() }",
            vec![],
        ))
        .expect_err("known custom effect cannot invent an operation");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));

        for source in [
            "fn bad(value: console::Item) {}",
            "effect alias IO = {console}; fn bad(value: IO::Item) {}",
            "fn bad() { console::missing }",
            "effect Named {} fn bad(value: Named::Item) {}",
            "effect Named { fn operation() -> Unit; } fn bad() { Named::operation() }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("Effect identities cannot serve as type-relative selection bases");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::UnresolvedName { .. }
            ));
        }

        resolve_project(&project(
            "fn ok<T>(value: T::Item) {} fn host() -> Unit with {console} { () }",
            vec![],
        ))
        .expect("generic selection and language effects remain legal in their own contexts");
    }

    #[test]
    fn expression_paths_do_not_load_file_sources() {
        let diagnostic = resolve_project(&project(
            "fn main() { dormant::call() }",
            vec![(vec!["dormant"], "@bad")],
        ))
        .expect_err("ordinary expression path cannot make a file source reachable");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "call"
        ));
    }

    #[test]
    fn protected_bindings_are_reserved_only_in_their_namespace() {
        let diagnostic = resolve_project(&project("struct Int {}", vec![]))
            .expect_err("language type cannot be redeclared");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding {
                namespace: NameNamespace::Type,
                ref name,
                ..
            } if name == "Int"
        ));

        resolve_project(&project("fn Int() -> Int { 1 }", vec![]))
            .expect("same spelling in value namespace is independent");
        resolve_project(&project(
            "fn Self() -> Int { 1 } fn call() -> Int { Self() }",
            vec![],
        ))
        .expect("special Type spelling does not occupy the Value namespace");

        for (source, namespace, expected_name) in [
            ("fn bad(value: Item) {}", NameNamespace::Type, "Item"),
            ("fn bad() { eq }", NameNamespace::Value, "eq"),
            ("fn bad() { raise }", NameNamespace::Value, "raise"),
        ] {
            let diagnostic = resolve_project(&project(source, vec![])).expect_err(
                "owner-scoped core and Language members are not implicit root bindings",
            );
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: actual,
                    ref name,
                } if actual == namespace && name == expected_name
            ));
        }

        resolve_project(&project(
            "type Item = Int; fn eq() -> Int { 1 } fn raise(value: Int) -> Int { value } fn call(value: Item) -> Int { eq() + raise(value) }",
            vec![],
        ))
        .expect("source root bindings do not conflict with owner-scoped core or Language members");
        resolve_project(&project(
            "use PartialEq::eq; use Iterable::Item; use fail::raise; fn call(value: Item) { eq; raise(value); }",
            vec![],
        ))
        .expect("explicit owner-member imports still bind their exact Language entities");

        let diagnostic = resolve_project(&project("fn bad<Int>(value: Int) {}", vec![]))
            .expect_err("generic cannot shadow language type");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding { .. }
        ));

        for source in [
            "struct Bad<Int> {}",
            "enum Bad<Int> {}",
            "trait Bad<Int> {}",
            "effect Bad<Int> {}",
            "effect alias Bad<Int> = {};",
            "extern fn bad<Int>() with {};",
            "extern type Bad<Int>;",
            "type Bad<Int> = Int;",
            "struct Box {} impl<Int> Box {}",
            "trait Named {} struct Box {} impl<Int> Named for Box {}",
            "struct Box {} impl Box { fn bad<Int>() {} }",
            "trait Named { fn bad<Int>(); }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("every generic declaration entry reserves protected Type names");
            assert!(
                matches!(
                    diagnostic.kind,
                    ProjectDiagnosticKind::ReservedLanguageBinding {
                        namespace: NameNamespace::Type,
                        ref name,
                        ..
                    } if name == "Int"
                ),
                "{source}: {diagnostic:?}"
            );
        }

        for source in [
            "mod Int {}",
            "effect console {}",
            "use defs::Named as console;",
        ] {
            let modules = if source.starts_with("use ") {
                vec![(vec!["defs"], "pub effect Named {}")]
            } else {
                vec![]
            };
            let diagnostic = resolve_project(&project(source, modules))
                .expect_err("module, source, and import entry points reserve Language names");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::ReservedLanguageBinding { .. }
            ));
        }

        resolve_project(&project(
            "effect Int {} effect Self {} fn console() {} fn Self() -> Int { 1 } fn ok() -> Unit with {Self} { () }",
            vec![],
        ))
        .expect("Language and Self spellings remain legal in other namespaces");

        let diagnostic = resolve_project(&project(
            "use types::Thing as Self;",
            vec![(vec!["types"], "pub struct Thing {}")],
        ))
        .expect_err("import cannot occupy owner-scoped Self in the Type namespace");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::InvalidSelf {
                library: TEST_LIBRARY,
            }
        );

        for source in [
            "trait Bad { type Self; }",
            "struct Bad {} impl Bad { type Self = Bad; }",
            "trait Named { type Item; } struct Bad {} impl Named for Bad { type Self = Bad; }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("owner-scoped Type declaration cannot occupy Self");
            assert_eq!(
                diagnostic.kind,
                ProjectDiagnosticKind::InvalidSelf {
                    library: TEST_LIBRARY,
                }
            );
        }
        for source in [
            "trait Bad { type Int; }",
            "struct Bad {} impl Bad { type Int = Bad; }",
            "trait Named { type Item; } struct Bad {} impl Named for Bad { type Int = Bad; }",
        ] {
            let diagnostic = resolve_project(&project(source, vec![]))
                .expect_err("owner-scoped Type declaration cannot redefine a language type");
            assert!(matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::ReservedLanguageBinding {
                    namespace: NameNamespace::Type,
                    ref name,
                    ..
                } if name == "Int"
            ));
        }
    }

    #[test]
    fn result_and_diagnostic_are_stable_across_map_insertion_order() {
        let mut first = BTreeMap::new();
        first.insert(
            FileModulePath::new(["a"]).unwrap(),
            "pub fn item() -> Int { 1 }".to_owned(),
        );
        first.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        let mut second = BTreeMap::new();
        second.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        second.insert(
            FileModulePath::new(["a"]).unwrap(),
            "pub fn item() -> Int { 1 }".to_owned(),
        );
        let root = "use a::item; fn main() -> Int { item() }".to_owned();
        let left = resolve_project(&single_library_project(root.clone(), first))
            .expect("project resolves");
        let right = resolve_project(&single_library_project(root, second))
            .expect("project resolves independently of insertion order");
        assert_eq!(left, right);

        let bad_root = "use z;".to_owned();
        let left_error = resolve_project(&single_library_project(
            bad_root.clone(),
            left_source_maps(),
        ))
        .expect_err("reachable bad module fails");
        let right_error = resolve_project(&single_library_project(bad_root, right_source_maps()))
            .expect_err("same error with reverse construction");
        assert_eq!(left_error, right_error);
    }

    #[test]
    fn declaration_conflicts_are_ordered_by_source_span_not_spelling() {
        let diagnostic = resolve_project(&project(
            "fn z() {} fn z() {} struct S { field: Int, field: Int }",
            vec![],
        ))
        .expect_err("the earliest declaration conflict wins");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::NameConflict {
                namespace: NameNamespace::Value,
                ref name,
                ..
            } if name == "z"
        ));
        assert_eq!(
            diagnostic
                .primary
                .expect("first conflicting declaration")
                .span,
            Span::new(3, 4)
        );
        assert_eq!(
            diagnostic.related,
            vec![OriginRef {
                library: TEST_LIBRARY,
                source: SourceRef::Root,
                span: Span::new(13, 14),
            }]
        );

        let diagnostic = resolve_project(&project(
            "fn generic<T: Missing, T>() {} fn later() { missing_later }",
            vec![],
        ))
        .expect_err("an earlier generic bound beats a later table-level duplicate");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "Missing"
        ));

        let diagnostic = resolve_project(&project(
            "use z; use a;",
            vec![
                (vec!["z"], "fn body() { missing_z }"),
                (vec!["a"], "fn body() { missing_a }"),
            ],
        ))
        .expect_err("body-name diagnostics use logical module order");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing_a"
        ));
        assert_eq!(
            diagnostic.primary.expect("body error source").source,
            SourceRef::File(FileModulePath::new(["a"]).unwrap())
        );

        let diagnostic = resolve_project(&project(
            "fn first() { missing_first } fn second() { missing_second }",
            vec![],
        ))
        .expect_err("sibling body units use source span rather than declaration spelling");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing_first"
        ));
    }

    fn left_source_maps() -> BTreeMap<FileModulePath, String> {
        let mut modules = BTreeMap::new();
        modules.insert(FileModulePath::new(["a"]).unwrap(), "fn ok() {}".to_owned());
        modules.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        modules
    }

    fn right_source_maps() -> BTreeMap<FileModulePath, String> {
        let mut modules = BTreeMap::new();
        modules.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        modules.insert(FileModulePath::new(["a"]).unwrap(), "fn ok() {}".to_owned());
        modules
    }
}
