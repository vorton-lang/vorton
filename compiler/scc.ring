// scc.ring — Call graph construction + Tarjan SCC for B-122 checker pass ordering
//
// build_call_graph: traverses AST bodies of all Decl::Fn and Decl::Impl methods,
// collecting edges to registered top-level fn names.
//
// tarjan_scc: standard Tarjan algorithm, returns SCCs in reverse topological order
// (dependencies before dependents — leaf callees first, top-level callers last).

use ast::{Decl, Expr, Stmt, StringInterpPart}
use hir::{compare_by_first}

// ============================================================
// Collect registered fn names from decls (mirrors Pass 1 registration)
// ============================================================

// Value and impl callables have disjoint scheduler domains. Impl method leaf
// names must not shadow a same-spelled top-level or inline value node.
pub fn collect_registered_fn_names(decls: List<Decl>) -> Set<Str> {
    let mut names: Set<Str> = set_new()
    collect_fn_names_from_decls(decls, names, none)
    names
}

fn collect_fn_names_from_decls(decls: List<Decl>, mut names: Set<Str>, mod_prefix: Str?) {
    for decl in decls {
        match decl {
            Decl::Fn { name, .. } => {
                let full_name = match mod_prefix { some(p) => "${p}::${name}", none => name }
                names.insert(full_name)
            },
            Decl::Impl { .. } => {},
            Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
                let prefix = match mod_prefix { some(p) => "${p}::${mod_name}", none => mod_name }
                collect_fn_names_from_decls(mod_decls, names, some(prefix))
            },
            _ => {}
        }
    }
}

// ============================================================
// Call graph construction
// ============================================================

// Build a call graph over top-level function names.
// Nodes: every fn name in registered_fns.
// Edges: caller -> callee, where callee is an Ident in a Call expr that appears in registered_fns.
//
// For impl blocks, all methods share a single node "impl::TypeName" (or "impl::TypeName::TraitName").
// Self.method() calls within the same impl produce no external edge.
fn impl_scc_node(target_type: Str, trait_name: Str?) -> Str {
    match trait_name {
        some(name) => "impl::${target_type}::${name}",
        none => "impl::${target_type}"
    }
}

pub fn build_call_graph(decls: List<Decl>, registered_fns: Set<Str>) -> Map<Str, List<Str>> {
    let mut graph: Map<Str, List<Str>> = map_new()

    // Ensure every registered fn has an entry (even if no outgoing edges).
    // Sort to ensure deterministic graph construction order across backends.
    let mut sorted_names: List<Str> = []
    for name in registered_fns { sorted_names.push(name) }
    sorted_names.sort()
    for name in sorted_names {
        if !graph.contains_key(name) {
            graph.insert(name, [])
        }
    }

    let mut root_scope = ""
    for name in sorted_names {
        let parts = name.split("$$_")
        if root_scope == "" && parts.len() > 1 {
            root_scope = "${parts.get(0).unwrap_or("")}$$_"
        }
    }
    for decl in decls {
        collect_decl_edges(
            decl, registered_fns, graph, none, root_scope)
    }
    graph
}

// Collect edges from a declaration.
// impl_node: if set, we are inside an impl block and edges go from this node.
fn collect_decl_edges(
    decl: Decl, registered_fns: Set<Str>,
    mut graph: Map<Str, List<Str>>, impl_node: Str?, lexical_scope: Str
) {
    match decl {
        Decl::Fn { name, body, .. } => {
            let caller = match impl_node { some(inode) => inode, none => name }
            if !graph.contains_key(caller) {
                graph.insert(caller, [])
            }
            let mut edges: Set<Str> = set_new()
            let scope = match impl_node {
                some(_) => lexical_scope,
                none => fn_scope_prefix(caller)
            }
            collect_expr_callees(body, registered_fns, scope, edges)
            let mut sorted_edges: List<Str> = []
            for e in edges {
                // Keep self edges: a singleton SCC is recursive only when its
                // own call edge survives graph construction.
                sorted_edges.push(e)
            }
            sorted_edges.sort()
            match graph.get(caller) {
                some(existing) => {
                    for e in sorted_edges { existing.push(e) }
                },
                none => {
                    graph.insert(caller, sorted_edges)
                }
            }
        },
        Decl::Impl { target_type, trait_name, methods, .. } => {
            let inode = impl_scc_node(target_type, trait_name)
            if !graph.contains_key(inode) {
                graph.insert(inode, [])
            }
            for method in methods {
                collect_decl_edges(
                    method, registered_fns, graph,
                    some(inode), lexical_scope)
            }
        },
        Decl::ModBlock { name, decls, .. } => {
            for d in decls {
                // ModBlock fns are prefixed with "mod_name::" by prefix_decl_name,
                // but at call-graph time we see the raw AST before prefixing.
                // The registered_fns set has the prefixed names.
                // We need to prefix here to match.
                let prefixed = prefix_mod_decl(name, d)
                collect_decl_edges(
                    prefixed, registered_fns, graph,
                    impl_node, "${name}::")
            }
        },
        // Test, Struct, Enum, Effect, Trait, ExternFn, ExternType, TypeAlias, Const,
        // EffectAlias, Delegate, AssocType — no fn bodies to scan
        _ => {}
    }
}

// Prefix a declaration name for ModBlock scoping (mirrors prefix_decl_name logic).
fn prefix_mod_decl(mod_name: Str, decl: Decl) -> Decl {
    match decl {
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, is_abstract, span } =>
            Decl::Fn { name: "${mod_name}::${name}", type_params: type_params, params: params,
                return_type: return_type, declared_effects: declared_effects, body: body,
                is_pub: is_pub, is_abstract: is_abstract, span: span },
        Decl::Impl { target_type, type_params, trait_name, methods, span } => {
            let prefixed_target = if target_type.contains("::") {
                target_type
            } else {
                "${mod_name}::${target_type}"
            }
            Decl::Impl { target_type: prefixed_target,
                type_params: type_params, trait_name: trait_name,
                methods: methods, span: span }
        },
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            Decl::ModBlock { name: "${mod_name}::${name}", uses: uses,
                decls: decls, required_effects: required_effects,
                is_pub: is_pub, span: span },
        _ => decl
    }
}

// ============================================================
// AST expression/statement traversal — collect callee names
// ============================================================
// Unified walker for two modes (#193):
//   TopLevel:    collect Ident callees from Call exprs matching registered_fns
//   SelfMethod:  collect self.method() callees matching impl method_names
//
// The mode enum selects which Call/MethodCall logic fires; all other AST
// traversal is shared.

enum CalleeMode {
    TopLevel { registered_fns: Set<Str>, scope_prefix: Str },
    SelfMethod { method_names: Set<Str> }
}

fn scc_file_root(scope_prefix: Str) -> Str {
    let parts = scope_prefix.split("$$_")
    if parts.len() > 1 { "${parts.get(0).unwrap_or("")}$$_" } else { "" }
}

fn scc_inline_scope(scope_prefix: Str) -> List<Str> {
    let mut scope = scope_prefix
    if scope.ends_with("::") { scope = scope.slice(0, scope.len() - 2) }
    let root_parts = scope.split("$$_")
    let inline_text = if root_parts.len() > 1 {
        root_parts.get(1).unwrap_or("")
    } else {
        scope
    }
    if inline_text == "" { [] } else { inline_text.split("::") }
}

fn scc_join_name(root: Str, inline_parts: List<Str>, name: Str) -> Str {
    if inline_parts.len() == 0 { return "${root}${name}" }
    "${root}${inline_parts.join("::")}::${name}"
}

// `self` preserves the current inline scope; each leading `super` removes one
// level.  Returning none on over-pop prevents a bogus fallback edge.
fn resolve_relative_callee(scope_prefix: Str, qualifier: Str, name: Str) -> Str? {
    let root = scc_file_root(scope_prefix)
    let mut inline_parts = scc_inline_scope(scope_prefix)
    let qualifier_parts = qualifier.split("::")
    let mut index = 0
    if qualifier_parts.get(0).unwrap_or("") == "self" {
        index = 1
    } else {
        while index < qualifier_parts.len() && qualifier_parts.get(index).unwrap_or("") == "super" {
            if inline_parts.len() == 0 { return none }
            inline_parts.pop()
            index = index + 1
        }
    }
    while index < qualifier_parts.len() {
        inline_parts.push(qualifier_parts.get(index).unwrap_or(""))
        index = index + 1
    }
    some(scc_join_name(root, inline_parts, name))
}

fn walk_expr_callees(expr: Expr, mode: CalleeMode, mut callees: Set<Str>) {
    match expr {
        Expr::Call { callee, args, .. } => {
            // TopLevel: check if callee is a direct Ident referencing a registered fn
            match mode {
                CalleeMode::TopLevel { registered_fns, scope_prefix } => {
                    match callee {
                        Expr::Ident { name, qualifier, .. } => {
                            match qualifier {
                                some(q) => {
                                    if q == "self" || q.starts_with("self::") || q == "super" || q.starts_with("super::") {
                                        match resolve_relative_callee(scope_prefix, q, name) {
                                            some(exact_name) => {
                                                if registered_fns.contains(exact_name) { callees.insert(exact_name) }
                                            },
                                            none => {}
                                        }
                                    } else {
                                        let root = scc_file_root(scope_prefix)
                                        let root_candidate = scc_join_name(root, q.split("::"), name)
                                        if registered_fns.contains(root_candidate) {
                                            callees.insert(root_candidate)
                                        } else {
                                            let mut current_parts = scc_inline_scope(scope_prefix)
                                            current_parts.extend(q.split("::"))
                                            let current_candidate = scc_join_name(root, current_parts, name)
                                            if registered_fns.contains(current_candidate) { callees.insert(current_candidate) }
                                        }
                                    }
                                },
                                none => {
                                    let root = scc_file_root(scope_prefix)
                                    let scoped_name = scc_join_name(root, scc_inline_scope(scope_prefix), name)
                                    if registered_fns.contains(scoped_name) {
                                        callees.insert(scoped_name)
                                    } else {
                                        let root_name = "${root}${name}"
                                        if registered_fns.contains(root_name) { callees.insert(root_name) }
                                    }
                                }
                            }
                        },
                        _ => {}
                    }
                },
                CalleeMode::SelfMethod { .. } => {}
            }
            // Recurse into callee expr and args
            walk_expr_callees(callee, mode, callees)
            for arg in args {
                walk_expr_callees(arg, mode, callees)
            }
        },
        Expr::MethodCall { receiver, method, args, .. } => {
            // SelfMethod: check if this is self.method() where method is in the impl
            match mode {
                CalleeMode::SelfMethod { method_names } => {
                    match receiver {
                        Expr::Ident { name, .. } => {
                            if name == "self" && method_names.contains(method) {
                                callees.insert(method)
                            }
                        },
                        _ => {}
                    }
                },
                CalleeMode::TopLevel { .. } => {}
            }
            walk_expr_callees(receiver, mode, callees)
            for arg in args {
                walk_expr_callees(arg, mode, callees)
            }
        },
        Expr::Ident { .. } => {
            // Bare ident (not in Call position) — not a call, skip
        },
        Expr::Block { stmts, tail, .. } => {
            for stmt in stmts {
                walk_stmt_callees(stmt, mode, callees)
            }
            match tail {
                some(t) => walk_expr_callees(t, mode, callees),
                none => {}
            }
        },
        Expr::IfExpr { condition, then_branch, else_branch, .. } => {
            walk_expr_callees(condition, mode, callees)
            walk_expr_callees(then_branch, mode, callees)
            match else_branch {
                some(eb) => walk_expr_callees(eb, mode, callees),
                none => {}
            }
        },
        Expr::MatchExpr { scrutinee, arms, .. } => {
            walk_expr_callees(scrutinee, mode, callees)
            for arm in arms {
                match arm.guard {
                    some(g) => walk_expr_callees(g, mode, callees),
                    none => {}
                }
                walk_expr_callees(arm.body, mode, callees)
            }
        },
        Expr::Lambda { body, .. } => {
            walk_expr_callees(body, mode, callees)
        },
        Expr::BinOp { left, right, .. } => {
            walk_expr_callees(left, mode, callees)
            walk_expr_callees(right, mode, callees)
        },
        Expr::UnaryOp { operand, .. } => {
            walk_expr_callees(operand, mode, callees)
        },
        Expr::FieldAccess { receiver, .. } => {
            walk_expr_callees(receiver, mode, callees)
        },
        Expr::IndexExpr { receiver, index, .. } => {
            walk_expr_callees(receiver, mode, callees)
            walk_expr_callees(index, mode, callees)
        },
        Expr::StructLit { fields, spread, .. } => {
            for f in fields {
                walk_expr_callees(f.value, mode, callees)
            }
            match spread {
                some(s) => walk_expr_callees(s, mode, callees),
                none => {}
            }
        },
        Expr::CatchExpr { expr: inner, arms, .. } => {
            walk_expr_callees(inner, mode, callees)
            for arm in arms {
                match arm.guard {
                    some(g) => walk_expr_callees(g, mode, callees),
                    none => {}
                }
                walk_expr_callees(arm.body, mode, callees)
            }
        },
        Expr::HandleExpr { body, handlers, .. } => {
            walk_expr_callees(body, mode, callees)
            for handler in handlers {
                walk_expr_callees(handler.body, mode, callees)
            }
        },
        Expr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    StringInterpPart::ExprPart(e) => walk_expr_callees(e, mode, callees),
                    StringInterpPart::LitPart(_) => {}
                }
            }
        },
        Expr::Range { start, end, .. } => {
            walk_expr_callees(start, mode, callees)
            walk_expr_callees(end, mode, callees)
        },
        Expr::ListLit { elements, .. } => {
            for el in elements {
                walk_expr_callees(el, mode, callees)
            }
        },
        Expr::TupleLit { elements, .. } => {
            for el in elements {
                walk_expr_callees(el, mode, callees)
            }
        },
        // Leaf expressions — no sub-expressions to traverse
        Expr::IntLit { .. } => {},
        Expr::FloatLit { .. } => {},
        Expr::StrLit { .. } => {},
        Expr::BoolLit { .. } => {},
        // B-113: return in expression position (match arm)
        Expr::ReturnExpr { value, .. } => match value {
            some(v) => walk_expr_callees(v, mode, callees),
            none => {}
        },
        // B-125: unsafe block — walk the body
        Expr::UnsafeBlock { body, .. } => walk_expr_callees(body, mode, callees)
    }
}

fn walk_stmt_callees(stmt: Stmt, mode: CalleeMode, mut callees: Set<Str>) {
    match stmt {
        Stmt::Let { init, .. } => walk_expr_callees(init, mode, callees),
        Stmt::Var { init, .. } => walk_expr_callees(init, mode, callees),
        Stmt::Assign { target, value, .. } => {
            walk_expr_callees(target, mode, callees)
            walk_expr_callees(value, mode, callees)
        },
        Stmt::ExprStmt { expr, .. } => walk_expr_callees(expr, mode, callees),
        Stmt::Return { value, .. } => match value {
            some(v) => walk_expr_callees(v, mode, callees),
            none => {}
        },
        Stmt::While { condition, body, .. } => {
            walk_expr_callees(condition, mode, callees)
            walk_expr_callees(body, mode, callees)
        },
        Stmt::ForIn { iterable, body, .. } => {
            walk_expr_callees(iterable, mode, callees)
            walk_expr_callees(body, mode, callees)
        },
        Stmt::LetDestructure { init, .. } => walk_expr_callees(init, mode, callees),
        Stmt::IfLet { expr, then_block, else_block, .. } => {
            walk_expr_callees(expr, mode, callees)
            walk_expr_callees(then_block, mode, callees)
            match else_block {
                some(eb) => walk_expr_callees(eb, mode, callees),
                none => {}
            }
        },
        Stmt::Break { .. } => {},
        Stmt::Continue { .. } => {}
    }
}

// Thin wrappers preserving original call-site signatures.
fn fn_scope_prefix(fn_name: Str) -> Str {
    let inline_parts = fn_name.split("::")
    if inline_parts.len() > 1 {
        let mut scope_parts: List<Str> = []
        for i in 0..inline_parts.len() - 1 {
            match inline_parts.get(i) { some(p) => scope_parts.push(p), none => {} }
        }
        return "${scope_parts.join("::")}::"
    }
    let module_parts = fn_name.split("$$_")
    if module_parts.len() > 1 {
        return "${module_parts.get(0).unwrap_or("")}$$_"
    }
    ""
}

fn collect_expr_callees(
    expr: Expr, registered_fns: Set<Str>, scope_prefix: Str,
    mut callees: Set<Str>
) {
    walk_expr_callees(expr, CalleeMode::TopLevel {
        registered_fns: registered_fns,
        scope_prefix: scope_prefix
    }, callees)
}

// Collect self.method() callees within an AST expression body (B-138).
// Only captures MethodCall where receiver is Ident("self") and method name
// is in the provided method_names set. Used for impl-internal SCC ordering.
pub fn collect_self_method_callees(expr: Expr, method_names: Set<Str>, mut callees: Set<Str>) {
    walk_expr_callees(expr, CalleeMode::SelfMethod { method_names: method_names }, callees)
}

// ============================================================
// Tarjan SCC
// ============================================================

// Standard Tarjan's algorithm for strongly connected components.
// Returns SCCs in reverse topological order: leaf dependencies come first,
// root callers come last.
pub fn tarjan_scc(graph: Map<Str, List<Str>>) -> List<List<Str>> {
    // index_counter is wrapped in a List<Int> (length-1) so that recursive calls
    // share the same mutable counter — Int is a value type in Ring, so `mut Int`
    // increments would not propagate back to the caller (#181).
    let mut index_counter: List<Int> = [0]
    let mut stack: List<Str> = []
    let mut on_stack: Set<Str> = set_new()
    let mut indices: Map<Str, Int> = map_new()
    let mut lowlinks: Map<Str, Int> = map_new()
    let mut result: List<List<Str>> = []

    // Collect all nodes (some might only appear as targets, not keys)
    let mut all_nodes: Set<Str> = set_new()
    let mut sorted_graph = graph.entries()
    sorted_graph.sort_by(compare_by_first)
    for entry in sorted_graph {
        let (node, targets) = entry
        all_nodes.insert(node)
        for t in targets {
            all_nodes.insert(t)
        }
    }

    let mut sorted_nodes: List<Str> = []
    for n in all_nodes { sorted_nodes.push(n) }
    sorted_nodes.sort()
    for node in sorted_nodes {
        if !indices.contains_key(node) {
            tarjan_strongconnect(node, graph, index_counter, stack, on_stack, indices, lowlinks, result)
        }
    }
    result
}

fn tarjan_strongconnect(
    v: Str,
    graph: Map<Str, List<Str>>,
    mut index_counter: List<Int>,
    mut stack: List<Str>,
    mut on_stack: Set<Str>,
    mut indices: Map<Str, Int>,
    mut lowlinks: Map<Str, Int>,
    mut result: List<List<Str>>
) {
    let v_index = index_counter[0]
    index_counter.set(0, index_counter[0] + 1)
    indices.insert(v, v_index)
    lowlinks.insert(v, v_index)
    stack.push(v)
    on_stack.insert(v)

    // Visit successors
    let successors = match graph.get(v) { some(s) => s, none => [] }
    for w in successors {
        if !indices.contains_key(w) {
            // w has not been visited; recurse
            tarjan_strongconnect(w, graph, index_counter, stack, on_stack, indices, lowlinks, result)
            let v_low = lowlinks.get(v).unwrap_or(0)
            let w_low = lowlinks.get(w).unwrap_or(0)
            if w_low < v_low {
                lowlinks.insert(v, w_low)
            }
        } else if on_stack.contains(w) {
            // w is on the stack, so it's part of the current SCC
            let v_low = lowlinks.get(v).unwrap_or(0)
            let w_idx = indices.get(w).unwrap_or(0)
            if w_idx < v_low {
                lowlinks.insert(v, w_idx)
            }
        }
    }

    // If v is a root node, pop the SCC
    let v_low = lowlinks.get(v).unwrap_or(0)
    let v_idx = indices.get(v).unwrap_or(0)
    if v_low == v_idx {
        let mut scc: List<Str> = []
        let mut done = false
        while !done {
            match stack.pop() {
                some(w) => {
                    on_stack.remove(w)
                    scc.push(w)
                    if w == v { done = true }
                },
                none => { done = true }
            }
        }
        result.push(scc)
    }
}
