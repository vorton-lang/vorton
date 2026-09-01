pub enum Result<T, E> {
    Ok(T),
    Err(E),
}

pub impl<T, E> Result {
    pub fn map<U>(self, f: fn(T) -> U) -> Result<U, E> {
        match self {
            Result::Ok(v) => Result::Ok(f(v)),
            Result::Err(e) => Result::Err(e),
        }
    }

    pub fn and_then<U>(self, f: fn(T) -> Result<U, E>) -> Result<U, E> {
        match self {
            Result::Ok(v) => f(v),
            Result::Err(e) => Result::Err(e),
        }
    }

    pub fn unwrap_or(self, default: T) -> T {
        match self {
            Result::Ok(v) => v,
            Result::Err(_) => default,
        }
    }

    pub fn is_ok(self) -> Bool {
        match self {
            Result::Ok(_) => true,
            Result::Err(_) => false,
        }
    }

    pub fn is_err(self) -> Bool {
        match self {
            Result::Ok(_) => false,
            Result::Err(_) => true,
        }
    }
}

pub fn to_result<T, E>(f: fn() -> T) -> Result<T, E> {
    Result::Ok(f()) catch { e => Result::Err(e) }
}
