// Mirror of free_type_vars_in_env: iterate Map<Str,Struct>.entries(), destructure
// the (key, value) tuple, then read a List field of the struct.
struct Sch { ty: Int, tvars: List<Int>, bounds: List<Int>, def_id: Int? }

fn main() {
    let mut m: Map<Str, Sch> = map_new()
    m.insert("a", Sch { ty: 1, tvars: [10, 20], bounds: [], def_id: none })
    m.insert("b", Sch { ty: 2, tvars: [30], bounds: [99], def_id: some(5) })
    for entry in m.entries() {
        let (k, sch) = entry
        print("${k}: ty=${sch.ty} ntvars=${sch.tvars.len()} nbounds=${sch.bounds.len()}")
        for v in sch.tvars {
            print("  tvar=${v}")
        }
    }
}
