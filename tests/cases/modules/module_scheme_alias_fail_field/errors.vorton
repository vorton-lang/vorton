struct AliasFailure {
    code: Int,
    is_occurs_check: Bool,
}

fn inferred_failure() -> Int {
    fail.raise(AliasFailure { code: 17, is_occurs_check: true })
}

pub fn recover_inferred_failure() -> Int {
    inferred_failure() catch {
        error => if error.is_occurs_check { error.code } else { 0 },
    }
}
