pub extern fn read_file(path: Str) -> Str with {fs}
pub extern fn write_file(path: Str, content: Str) -> Unit with {fs}
pub extern fn file_exists(path: Str) -> Bool with {fs}
pub extern fn delete_file(path: Str) -> Unit with {fs}
