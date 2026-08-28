pub fn scalar_text(value: Int, decimal: Float) -> Str {
    "${" hi ".trim().to_upper()}:${value.to_str()}:${decimal.to_str()}"
}

pub fn option_value(value: Int) -> Int {
    some(value).map(fn(x) { x + 2 }).unwrap_or(0)
}

pub effect ProjectStep {
    fn apply(value: Int) -> Int
}

pub effect ProjectScale {
    fn apply(value: Int) -> Int
}

pub fn project_one(value: Int) -> Int with {ProjectStep} {
    ProjectStep.apply(value)
}

pub fn project_two(value: Int) -> Int with {ProjectStep, ProjectScale} {
    ProjectScale.apply(ProjectStep.apply(value))
}

pub fn project_compare(
    left: Int,
    right: Int
) -> Int with {ProjectStep} {
    ProjectStep.apply(left - right)
}
