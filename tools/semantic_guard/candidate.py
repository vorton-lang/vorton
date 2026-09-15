#!/usr/bin/env python3
"""Apply this frozen guard baseline to one exact implementation candidate."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from common import (
    GuardError,
    ROOT,
    exact_commit,
    guard_identity,
    load_manifest,
    observe_case,
    prepare_probe,
    require_observation,
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, help="exact candidate Git revision")
    parser.add_argument(
        "--repository",
        type=Path,
        default=ROOT,
        help="repository containing the candidate object",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = arguments.repository.resolve()
    baseline, dirty = guard_identity()
    if dirty:
        raise GuardError("candidate acceptance requires a clean guard baseline checkout")
    candidate = exact_commit(repository, arguments.candidate)
    if candidate != arguments.candidate:
        raise GuardError("--candidate must be the exact 40-hex commit, not a symbolic ref")
    print(
        f"GUARD_BASELINE={baseline} TESTED_SHA={candidate} "
        f"PURPOSE=implementation-candidate-acceptance"
    )
    executable = prepare_probe(repository, candidate, "candidate")
    cases = load_manifest()
    for case in cases:
        observation = observe_case(executable, case)
        require_observation(case, observation, "candidate")
    print(
        f"IMPLEMENTATION_CANDIDATE_ACCEPTANCE=COMPLETED BASELINE={baseline} "
        f"TESTED_SHA={candidate} CASES={len(cases)}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GuardError as error:
        print(f"INFRASTRUCTURE_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
