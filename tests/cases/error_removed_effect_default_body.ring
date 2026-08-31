// Ring 0.1 effect operations are signature-only. Recovery consumes exactly
// the rejected body and preserves the following operation/declaration.
effect RemovedDefault {
    fn rejected() -> Int { 1 }
    fn preserved() -> Int
}

fn after_effect() -> Int { 2 }
