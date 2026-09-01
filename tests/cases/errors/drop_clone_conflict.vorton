// expect-error: E0802
struct Res { id: Int }
impl Drop for Res { fn drop(self) {} }
impl Clone for Res { fn clone(self) -> Res { Res { id: self.id } } }
