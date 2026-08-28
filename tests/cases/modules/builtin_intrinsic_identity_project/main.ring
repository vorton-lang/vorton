use ops::{scalar_text, option_value, ProjectStep, ProjectScale,
    project_one, project_two, project_compare}

fn main() {
    let cell = Cell(option_value(5))
    cell.update(fn(x) { x + 5 })

    let pure_map = some(1).map(fn(x) { x + 1 }).unwrap_or(0)
    let pure_chain = some(2).and_then(fn(x) { some(x + 2) }).unwrap_or(0)
    let pure_none: Option<Int> = none
    let pure_fallback = pure_none.unwrap_or_else(fn() { 6 })
    assert(pure_map * 10000 + pure_chain * 100 + pure_fallback == 20406,
        "project Option callbacks accept the empty context")

    let one_effect = handle {
        let mapped = some(1).map(project_one).unwrap_or(0)
        let chained = some(2)
            .and_then(fn(x) { some(project_one(x)) })
            .unwrap_or(0)
        let missing: Option<Int> = none
        let fallback = missing.unwrap_or_else(fn() { project_one(3) })
        mapped * 10000 + chained * 100 + fallback
    } with {
        ProjectStep.apply(value) => value + 10,
    }
    assert(one_effect == 111213,
        "project Option callbacks receive one current handled entry")

    let two_effects = handle {
        let mapped = some(1).map(project_two).unwrap_or(0)
        let chained = some(2)
            .and_then(fn(x) { some(project_two(x)) })
            .unwrap_or(0)
        let missing: Option<Int> = none
        let fallback = missing.unwrap_or_else(fn() { project_two(3) })
        mapped * 10000 + chained * 100 + fallback
    } with {
        ProjectStep.apply(value) => value + 10,
        ProjectScale.apply(value) => value * 2,
    }
    assert(two_effects == 222426,
        "project Option callbacks preserve two exact handled entries")

    let mut callback_hits = 0
    let absent: Option<Int> = none
    let none_contract = handle {
        let mapped = absent.map(project_two)
        let chained = absent.and_then(fn(x) { some(project_two(x)) })
        let present = some(7).unwrap_or_else(fn() { project_two(99) })
        assert(mapped.is_none() && chained.is_none() && present == 7,
            "project Option non-callback branches preserve values")
        1
    } with {
        ProjectStep.apply(value) => {
            callback_hits = callback_hits + 1
            value
        },
        ProjectScale.apply(value) => {
            callback_hits = callback_hits + 1
            value
        },
    }
    assert(none_contract == 1 && callback_hits == 0,
        "project Option non-callback branches do not invoke closures")

    let owned = Cell("project")
    owned.update(fn(old) { "${old}-after" })
    let retained = owned.get()
    owned.set("done")
    assert(retained == "project-after" && owned.get() == "done",
        "project Cell update and later set preserve owned Str")

    let mut values = [3, 1, 2]
    let mut sort_calls = 0
    let sort_complete = handle {
        values.sort_by(project_compare)
        1
    } with {
        ProjectStep.apply(value) => {
            sort_calls = sort_calls + 1
            value
        },
    }
    assert(sort_complete == 1 && sort_calls > 0 &&
        values[0] == 1 && values[2] == 3,
        "project sort forwards its current context across modules")

    print("${scalar_text(7, 2.5)}|${cell.get()}")
}
