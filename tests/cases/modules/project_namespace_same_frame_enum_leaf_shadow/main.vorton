use origin

fn public_shared_score(value: PublicBeforePrivate) -> Int {
    match value {
        PublicBeforePrivate::Shared(number) => number,
    }
}

fn last_layered_score(value: LastPublic) -> Int {
    match value {
        LastPublic::Layered(number) => number,
    }
}

fn projected_score(value: projected::ProjectedLast) -> Int {
    match value {
        projected::ProjectedLast::Mirrored(number) => number,
    }
}

fn main() {
    print(local_private_leaf())
    print(exact_shared_members())
    print(local_direct_value())
    print(exact_layered_members())
    print(projected::local_mirrored())
    print(projected::exact_mirrored_members())
    print(public_shared_score(Shared(23)))
    print(last_layered_score(Layered(29)))
    print(projected_score(projected::Mirrored(53)))
    print(projected_score(projected::ProjectedLast::Mirrored(59)))
}
