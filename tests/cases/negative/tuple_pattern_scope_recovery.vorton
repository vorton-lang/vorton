// B-107: malformed tuple/constructor patterns still establish every syntactic
// binding with ErrorType. The `*_global` names deliberately collide with
// functions; the `*_local` names have no outer declaration. Recovery must not
// resolve either category as a global callable or an undefined identifier.

struct Record {
    value: Int,
}

enum PairBox {
    Pair(Int, Int),
}

fn tuple_global(value: Int) -> Int { value }
fn arity_global(value: Int) -> Int { value }
fn ctor_global(value: Int) -> Int { value }
fn named_global(value: Int) -> Int { value }
fn error_global(value: Int) -> Int { value }
fn nested_global(value: Int) -> Int { value }

fn non_tuple_recovery() -> Int {
    match 7 {
        (tuple_global, tuple_local) => tuple_global() + tuple_local(),
        _ => 0
    }
}

fn tuple_arity_recovery() -> Int {
    match (1, 2) {
        (left, right, arity_global, arity_local) =>
            arity_global() + arity_local(),
        _ => 0
    }
}

fn constructor_arity_recovery(value: PairBox) -> Int {
    match value {
        PairBox::Pair(left, right, ctor_global, ctor_local) =>
            ctor_global() + ctor_local(),
        _ => 0
    }
}

fn named_field_recovery(value: Record) -> Int {
    match value {
        Record {
            value: known,
            missing_global: named_global,
            missing_local: named_local,
        } => named_global() + named_local(),
        _ => 0
    }
}

fn error_type_recovery() -> Int {
    match 1[0] {
        (error_global, error_local) => error_global() + error_local(),
        _ => 0
    }
}

fn nested_constructor_recovery() -> Int {
    match 9 {
        (PairBox::Pair(nested_global, nested_local), _) =>
            nested_global() + nested_local(),
        _ => 0
    }
}

fn main() {}
