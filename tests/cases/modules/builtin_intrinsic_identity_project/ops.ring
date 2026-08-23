pub fn scalar_text(value: Int, decimal: Float) -> Str {
    "${" hi ".trim().to_upper()}:${value.to_str()}:${decimal.to_str()}"
}

pub fn option_value(value: Int) -> Int {
    some(value).map(fn(x) { x + 2 }).unwrap_or(0)
}
