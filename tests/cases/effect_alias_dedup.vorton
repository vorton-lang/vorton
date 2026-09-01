effect alias IO = {console, fail<Str>}

fn do_io() with {IO, console} {
    print("hello")
}

fn main() {
    do_io() catch { _ => {} }
    print("effect_alias_dedup: all tests passed")
}
