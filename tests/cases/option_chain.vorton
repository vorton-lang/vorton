// Test: Option chaining with to_fail method in various contexts

fn find_user(id: Int) -> Option<Str> {
    if id == 1 { some("alice") }
    else if id == 2 { some("bob") }
    else { none }
}

fn find_age(name: Str) -> Option<Int> {
    if name == "alice" { some(30) }
    else { none }
}

// Chain of to_fail operations — returns T via fail effect
fn get_user_age(id: Int) -> Int {
    let name = find_user(id).to_fail("user not found")
    let age = find_age(name).to_fail("age not found")
    age
}

// to_fail with method calls
fn first_positive(xs: List<Int>) -> Int {
    let found = xs.find(fn(x) { x > 0 }).to_fail("no positive")
    found * 10
}

fn main() {
    // Successful chain — use some()+catch to capture result as Option
    let age1 = some(get_user_age(1)) catch { _ => none }
    assert(age1.unwrap_or(0) == 30, "chain success")

    // First to_fail fails
    let age3 = some(get_user_age(3)) catch { _ => none }
    assert(age3.is_none(), "chain fail at first")

    // Second to_fail fails (bob has no age)
    let age2 = some(get_user_age(2)) catch { _ => none }
    assert(age2.is_none(), "chain fail at second")

    // to_fail with method calls
    let pos = some(first_positive([-1, -2, 5, 3])) catch { _ => none }
    assert(pos.unwrap_or(0) == 50, "to_fail with method chain")

    let no_pos = some(first_positive([-1, -2])) catch { _ => none }
    assert(no_pos.is_none(), "to_fail with method chain none")

    // catch as alternative
    let age_or = get_user_age(1) catch { _ => -1 }
    assert(age_or == 30, "catch with to_fail chain success")

    let age_or_fail = get_user_age(99) catch { _ => -1 }
    assert(age_or_fail == -1, "catch with to_fail chain fail")

    print("option_chain: all tests passed")
}
