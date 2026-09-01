pub fn identity<T>(value: T) -> T { value }

pub fn apply<T>(callback: fn(T) -> T, value: T) -> T {
    callback(value)
}

pub fn select<T>(callback: fn(T) -> T) -> fn(T) -> T {
    callback
}

pub fn increment(value: Int) -> Int { value + 1 }
pub fn suffix(value: Str) -> Str { "${value}!" }
