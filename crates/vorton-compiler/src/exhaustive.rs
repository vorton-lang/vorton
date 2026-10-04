//! Exhaustiveness of patterns, by Maranget's usefulness algorithm.
//!
//! `Bool`, `Unit`, tuples and enums have a closed set of constructors and
//! are split by constructor. `Int`, `Float`, `Str` and structs are open:
//! only a wildcard or a binding covers them.

use std::collections::BTreeSet;

use crate::typed::Pattern;
use crate::types::{Type, TypeKind, Types};

/// Returns a value of type `ty`, written as a pattern, that none of
/// `patterns` matches, or `None` when they cover every value.
pub(crate) fn missing(types: &Types, patterns: &[&Pattern], ty: Type) -> Option<String> {
    let rows = patterns
        .iter()
        .map(|pattern| vec![(*pattern).clone()])
        .collect();
    useful(types, rows, &[ty]).map(|mut witness| witness.remove(0))
}

/// Returns values of types `tys` that no row matches, if there are any.
fn useful(types: &Types, rows: Vec<Vec<Pattern>>, tys: &[Type]) -> Option<Vec<String>> {
    let Some((&first, rest)) = tys.split_first() else {
        return rows.is_empty().then(Vec::new);
    };
    let mut expanded = Vec::new();
    for row in rows {
        expand(row, &mut expanded);
    }
    let count = constructors(types, first);
    let present = expanded
        .iter()
        .filter_map(|row| head_constructor(&row[0]))
        .collect::<BTreeSet<_>>();
    // When the first column names every constructor, each one is checked
    // with the rows that match it. Otherwise only the rows with a wildcard
    // there can cover a missing constructor, and the column is done.
    if let Some(count) = count
        && present.len() == count
    {
        return (0..count).find_map(|constructor| {
            let fields = field_types(types, first, constructor);
            let arity = fields.len();
            let specialized = expanded
                .iter()
                .filter_map(|row| specialize(row, constructor, arity))
                .collect();
            let mut sub_types = fields;
            sub_types.extend_from_slice(rest);
            useful(types, specialized, &sub_types).map(|witness| {
                let (arguments, remaining) = witness.split_at(arity);
                let mut result = vec![describe(types, first, constructor, arguments)];
                result.extend_from_slice(remaining);
                result
            })
        });
    }
    let default = expanded
        .into_iter()
        .filter(|row| is_wild(&row[0]))
        .map(|row| row[1..].to_vec())
        .collect();
    useful(types, default, rest).map(|witness| {
        let missing =
            count.and_then(|count| (0..count).find(|constructor| !present.contains(constructor)));
        let head = match missing {
            Some(constructor) => {
                let arity = field_types(types, first, constructor).len();
                describe(types, first, constructor, &vec!["_".to_owned(); arity])
            }
            None => "_".to_owned(),
        };
        let mut result = vec![head];
        result.extend(witness);
        result
    })
}

/// The constructor a pattern of a closed type names, if it names one.
fn head_constructor(pattern: &Pattern) -> Option<usize> {
    match pattern {
        Pattern::Bool(value) => Some(usize::from(*value)),
        Pattern::Tuple(_) => Some(0),
        Pattern::Variant { variant, .. } => Some(*variant),
        _ => None,
    }
}

/// Splits or-patterns in the first column into separate rows.
fn expand(row: Vec<Pattern>, output: &mut Vec<Vec<Pattern>>) {
    if let Pattern::Or(alternatives) = &row[0] {
        for alternative in alternatives {
            let mut alternative_row = vec![alternative.clone()];
            alternative_row.extend_from_slice(&row[1..]);
            expand(alternative_row, output);
        }
    } else {
        output.push(row);
    }
}

fn is_wild(pattern: &Pattern) -> bool {
    matches!(pattern, Pattern::Wildcard | Pattern::Binding(..))
}

/// The number of constructors of a closed type, or `None` for an open one.
fn constructors(types: &Types, ty: Type) -> Option<usize> {
    match types.kind(ty) {
        TypeKind::Bool => Some(2),
        TypeKind::Unit | TypeKind::Tuple(_) => Some(1),
        TypeKind::Never => Some(0),
        TypeKind::Nominal { .. } if types.is_enum(ty) => Some(types.variants(ty).len()),
        _ => None,
    }
}

fn field_types(types: &Types, ty: Type, constructor: usize) -> Vec<Type> {
    match types.kind(ty) {
        TypeKind::Tuple(elements) => elements.clone(),
        TypeKind::Nominal { .. } => types.variants(ty)[constructor]
            .fields
            .iter()
            .map(|field| field.ty)
            .collect(),
        _ => Vec::new(),
    }
}

/// The row for values built by `constructor`, or `None` if the row's first
/// pattern cannot match them.
fn specialize(row: &[Pattern], constructor: usize, arity: usize) -> Option<Vec<Pattern>> {
    let mut result = match &row[0] {
        Pattern::Wildcard | Pattern::Binding(..) => vec![Pattern::Wildcard; arity],
        Pattern::Bool(value) => {
            if usize::from(*value) != constructor {
                return None;
            }
            Vec::new()
        }
        Pattern::Tuple(elements) => elements.clone(),
        Pattern::Variant { variant, fields } => {
            if *variant != constructor {
                return None;
            }
            let mut arguments = vec![Pattern::Wildcard; arity];
            for (index, pattern) in fields {
                arguments[*index] = pattern.clone();
            }
            arguments
        }
        Pattern::Int(_) | Pattern::Float(_) | Pattern::Str(_) | Pattern::Or(_) => {
            unreachable!("open types have no constructors and or-patterns are expanded")
        }
    };
    result.extend_from_slice(&row[1..]);
    Some(result)
}

fn describe(types: &Types, ty: Type, constructor: usize, arguments: &[String]) -> String {
    match types.kind(ty) {
        TypeKind::Bool => if constructor == 1 { "true" } else { "false" }.to_owned(),
        TypeKind::Unit => "()".to_owned(),
        TypeKind::Tuple(_) => format!("({})", arguments.join(", ")),
        TypeKind::Nominal { declaration, .. } => {
            let variant = &types.variants(ty)[constructor];
            let name = format!("{}::{}", types.nominals[*declaration].name, variant.name);
            if variant.fields.is_empty() {
                name
            } else if variant.fields[0].name.parse::<usize>().is_ok() {
                format!("{name}({})", arguments.join(", "))
            } else {
                let fields = variant
                    .fields
                    .iter()
                    .zip(arguments)
                    .map(|(field, argument)| format!("{}: {argument}", field.name))
                    .collect::<Vec<_>>();
                format!("{name} {{ {} }}", fields.join(", "))
            }
        }
        _ => "_".to_owned(),
    }
}
