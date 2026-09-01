struct Resource { id: Int }

impl Drop for Resource {
  fn drop(self) {}
}

struct Holder {
  item: Resource,
  label: Str,
}

fn fail_label() -> Str {
  fail.raise("override failed")
}

fn main() {
  let first = Holder { item: Resource { id: 7 }, label: "old" }
  let recovered = Holder { ..first, label: fail_label() } catch {
    _ => first
  }
  assert(recovered.item.id == 7, "failed RHS must leave base intact")
  assert(recovered.label == "old", "failed RHS must not commit override")

  let second = Holder { item: Resource { id: 9 }, label: "before" }
  let moved = Holder { ..second, label: "after" }
  assert(moved.item.id == 9, "missing field moves into fresh result")
  assert(moved.label == "after", "override replaces old field")
  print("STRUCT_UPDATE_MOVE_RESOURCE_OK")
}
