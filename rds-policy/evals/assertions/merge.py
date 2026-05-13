"""Merge assertions — artifact correctness.

Promptfoo Python assertion return format (GradingResult):
    {"pass_": bool, "score": float 0-1, "reason": str}

Snake_case keys are auto-converted to camelCase by promptfoo:
    pass_ -> pass, component_results -> componentResults.

All CR-specific values (names, jmespath paths, expected values) come from
the config block in promptfooconfig.yaml — this code is a generic engine.

Communication checks (conflict flagging, overlay lifecycle, checklist
quality) are handled by llm-rubric in promptfooconfig.yaml.
"""

import jmespath

from common import (
    collect_manifests,
    collect_written_files,
    find_first,
    parse_pg_docs,
)


def _fmt(name, passed, expected, actual):
    status = "PASS" if passed else "FAIL"
    return f"{status} {name} | EXPECTED: {expected} | ACTUAL: {actual}"


def _run_check(check, all_manifests, manifest_paths):
    """Run a single config-driven check. Returns (name, passed, expected, actual)."""
    name = check["name"]
    cr = check["cr"]
    check_type = check.get("type")

    if check_type == "exists":
        found = find_first(all_manifests, cr) is not None
        return (
            name,
            found,
            f"manifest containing '{cr}'",
            f"{'found' if found else 'not found'} in {len(all_manifests)} manifests",
        )

    if check_type == "not_exists":
        found = any(cr.lower() in p.lower() for p in manifest_paths)
        return (
            name,
            not found,
            f"no manifest containing '{cr}'",
            f"{'found (bad)' if found else 'absent (good)'}",
        )

    if check_type == "profile_content":
        return _check_profile_content(check, all_manifests)

    # Field check: cr + path, with optional contains/empty modifiers.
    # Search ALL matching manifests (not just the first) because a CR
    # may appear in multiple policies (e.g. PTP in primary + secondary).
    matches = [m for m in all_manifests if cr.lower() in m.get("path", "").lower()]
    m = matches[0] if matches else None
    path = check["path"]
    result = jmespath.search(path, m) if m else None

    if check.get("empty"):
        return (
            name,
            not bool(result),
            f"empty {path}",
            f"result={bool(result)}",
        )

    if "contains" in check:
        value = check["contains"]
        for candidate in matches:
            candidate_result = jmespath.search(path, candidate)
            if value in str(candidate_result or ""):
                return (name, True, f"'{value}' in {path}", "found")
        return (
            name,
            False,
            f"'{value}' in {path}",
            "not found",
        )

    return (
        name,
        m is not None and bool(result),
        f"non-empty {path}",
        f"manifest={'found' if m else 'missing'}, result={bool(result)}",
    )


def _check_profile_content(check, all_manifests):
    """Check that expected content exists in the correct named profile."""
    name = check["name"]
    cr = check["cr"]
    m = find_first(all_manifests, cr)
    if m is None:
        return (name, False, f"manifest '{cr}'", "not found")

    profiles = jmespath.search(check["profiles_path"], m) or []
    target_profile = check["profile_name_contains"]
    expected_content = check["data_contains"]
    expected_section = check.get("section_contains", "")

    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        pname = profile.get("name", "")
        data = profile.get("data", "")
        if expected_content not in data:
            continue
        in_target = target_profile in pname
        in_section = expected_section in data if expected_section else True
        if in_target and in_section:
            return (
                name,
                True,
                f"'{expected_content}' in profile '{target_profile}'",
                f"found in profile '{pname}'",
            )

    return (
        name,
        False,
        f"'{expected_content}' in profile '{target_profile}'",
        f"not found in {len(profiles)} profiles",
    )


def check_file_content(_output, context):
    """Verify the merge produced correct YAML artifacts using config-driven checks.

    Version bump checks (name, namespace, labels) are handled by
    check_multi_pg_structure which validates ALL PG docs, not just the first.
    """
    config = context["config"]

    written = collect_written_files(context)

    if not written:
        return {
            "pass_": False,
            "score": 0,
            "reason": "EXPECTED: written files | ACTUAL: no files found",
        }

    pg_docs, skipped = parse_pg_docs(written, strict=True)

    if not pg_docs:
        return {
            "pass_": False,
            "score": 0,
            "reason": f"EXPECTED: PolicyGenerator docs | ACTUAL: 0 PG docs, {len(skipped)} non-PG skipped: {[s.get('kind', s.get('error', '?')) for s in skipped]}",
        }

    all_manifests = collect_manifests(pg_docs)
    manifest_paths = [m.get("path", "") for m in all_manifests]

    checks = [_run_check(c, all_manifests, manifest_paths) for c in config["checks"]]

    total = len(checks)
    num_passed = sum(1 for _, passed, _, _ in checks if passed)

    return {
        "pass_": num_passed == total,
        "score": num_passed / total,
        "reason": f"{num_passed}/{total} artifact checks passed ({len(skipped)} non-PG: {[s.get('kind', s.get('error', '?')) for s in skipped]})",
        "component_results": [
            {
                "pass_": bool(passed),
                "score": 1.0 if passed else 0.0,
                "reason": _fmt(name, passed, expected, actual),
            }
            for name, passed, expected, actual in checks
        ],
    }
