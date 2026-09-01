pub enum Problem {
    Failed(Int),
}

fn fail_now() -> Int {
    fail.raise(Problem::Failed(17))
}

fn via_helper() -> Int {
    fail_now()
}

pub fn recovered() -> Int {
    via_helper() catch {
        Problem::Failed(code) => code,
    }
}
