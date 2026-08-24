// Unique neutral transport from the checker's canonical Type graph to one
// module-local Core type fact.  It is consumed by Core assembly and legacy
// projection; neither consumer may rebuild the relation.

use types::{Type, types_equal}
use core_expr::{CoreTypeFactRef, core_type_fact_same}

pub struct CoreTypeSourceFact {
    source_type: Type,
    type_fact: CoreTypeFactRef
}

pub fn make_core_type_source_fact(
    source_type: Type, type_fact: CoreTypeFactRef
) -> CoreTypeSourceFact {
    CoreTypeSourceFact { source_type: source_type, type_fact: type_fact }
}
pub fn core_type_source_type(value: CoreTypeSourceFact) -> Type {
    value.source_type
}
pub fn core_type_source_fact(value: CoreTypeSourceFact) -> CoreTypeFactRef {
    value.type_fact
}
pub fn core_type_source_same(
    left: CoreTypeSourceFact, right: CoreTypeSourceFact
) -> Bool {
    types_equal(left.source_type, right.source_type) &&
        core_type_fact_same(left.type_fact, right.type_fact)
}
