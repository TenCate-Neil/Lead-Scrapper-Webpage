#!/usr/bin/env python3
"""PostToolUse hook: validate pipeline artifacts against the JSON Schemas in contracts/.

Claude Code runs this after every Write/Edit (see .claude/settings.json). It reads
the hook payload on stdin, learns which file was written from
`tool_input.file_path`, and — if that file is a known pipeline artifact — validates
its on-disk contents against the matching contract:

    output/**/sources.json        -> contracts/source.schema.json        (wrapper doc; each item)
    output/**/leads.json          -> contracts/lead.schema.json          (wrapper doc; each item)
    output/**/run_manifest.json   -> contracts/run_manifest.schema.json  (whole object)
    sources/registry.json         -> contracts/source.schema.json        (wrapper doc; each item)
    organizations/registry.json   -> contracts/organization.schema.json  (wrapper doc; each item)
    leads/ledger.json             -> contracts/lead.schema.json          (wrapper doc; each item)

sources.json / leads.json and the durable registries are wrapper documents of the
shape {"schema_version": "<ver>", ["location_id": "...",] <key>: [ ...items... ]};
the wrapper's schema_version (per-route expected value) and — for per-run output
files — location_id are checked, and each inner item is validated against the
item schema. A bare top-level array is also accepted.
    locations/registry.yaml     -> contracts/location.schema.json       (each record)
    locations/state.json        -> contracts/location_state.schema.json (each record)

Any other file is ignored (exit 0). The hook is intentionally dependency-optional:

  * If `jsonschema` is not importable, it prints a warning to stderr and exits 0 so
    a missing dev dependency never blocks the user's workflow.
  * If a YAML artifact is written but `PyYAML` is not importable, same behavior.
  * On a schema violation (or unparseable JSON/YAML in a target file) it prints the
    errors to stderr and exits 2, so the failing write is surfaced back to Claude.
  * On any unexpected internal error it warns and exits 0 (never block on a hook bug).

Contracts are located relative to this file (project_root/contracts), with
$CLAUDE_PROJECT_DIR taking precedence when set, so the hook works regardless of the
process working directory.
"""

import json
import os
import sys

try:
    import jsonschema
except Exception:  # ImportError or partial install
    jsonschema = None

try:
    import yaml
except Exception:
    yaml = None


def _warn(msg):
    sys.stderr.write("[validate_schema] " + msg + "\n")


def project_dir(script_path):
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return os.path.abspath(env)
    # .claude/hooks/validate_schema.py -> project root is three levels up.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(script_path))))


def route(abs_path, root, contracts):
    """Map an absolute file path to a routing tuple, or None to skip.

    Returns (schema_path, kind, list_keys, expected_version, require_location).
    kind is one of: 'array' (validate each list item), 'object' (validate the
    whole doc), 'wrapper' (versioned wrapper doc; validate each inner item),
    'records' (extract records from list/wrapper/map, validate each).
    expected_version / require_location only apply to 'wrapper' routes.
    """
    rel = os.path.relpath(abs_path, root)
    parts = rel.split(os.sep)
    if not parts or parts[0] == "..":
        return None  # outside the project tree
    top = parts[0]
    base = os.path.basename(abs_path)

    if top == "output":
        output_map = {
            "sources.json": ("source.schema.json", "wrapper", ["sources"], "2.1", True),
            "leads.json": ("lead.schema.json", "wrapper", ["leads"], "2.0", True),
            "run_manifest.json": ("run_manifest.schema.json", "object", [], None, False),
        }
        if base in output_map:
            schema_file, kind, keys, version, req_loc = output_map[base]
            return (os.path.join(contracts, schema_file), kind, keys, version, req_loc)
    elif top == "sources" and base == "registry.json":
        return (os.path.join(contracts, "source.schema.json"), "wrapper", ["sources"],
                "2.1", False)
    elif top == "organizations" and base == "registry.json":
        return (os.path.join(contracts, "organization.schema.json"), "wrapper",
                ["organizations"], "1.0", False)
    elif top == "leads" and base == "ledger.json":
        return (os.path.join(contracts, "lead.schema.json"), "wrapper", ["leads"],
                "2.0", False)
    elif top == "locations":
        if base == "registry.yaml":
            return (os.path.join(contracts, "location.schema.json"), "records",
                    ["locations"], None, False)
        if base == "state.json":
            return (os.path.join(contracts, "location_state.schema.json"), "records",
                    ["states", "locations"], None, False)
    return None


def load_doc(path):
    """Return the parsed document, or raise on parse error / signal missing yaml."""
    ext = os.path.splitext(path)[1].lower()
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if ext in (".yaml", ".yml"):
        if yaml is None:
            return None, "yaml_missing"
        return yaml.safe_load(text), None
    return json.loads(text), None


def extract_records(doc, list_keys):
    """Normalize registry/state files to a list of records.

    Supports three shapes: a bare list; a single record (has 'location_id'); a
    wrapper object with a list under one of list_keys; or a map keyed by id.
    """
    if isinstance(doc, list):
        return doc
    if not isinstance(doc, dict):
        return [doc]
    if "location_id" in doc:  # a single record carries its own foreign key
        return [doc]
    for key in list_keys:
        if isinstance(doc.get(key), list):
            return doc[key]
    values = list(doc.values())
    if values and all(isinstance(v, dict) for v in values):
        return values  # map keyed by location_id
    return [doc]


def make_validator(schema):
    fmt = jsonschema.FormatChecker() if hasattr(jsonschema, "FormatChecker") else None
    for name in ("Draft202012Validator", "Draft201909Validator", "Draft7Validator"):
        cls = getattr(jsonschema, name, None)
        if cls is not None:
            return cls(schema, format_checker=fmt) if fmt is not None else cls(schema)
    return None


def validate_instance(instance, schema, label):
    """Return a list of human-readable error strings ('' free means valid)."""
    errors = []
    validator = make_validator(schema)
    if validator is not None:
        for err in sorted(validator.iter_errors(instance), key=lambda e: list(e.path)):
            loc = "/".join(str(p) for p in err.path) or "<root>"
            errors.append("{0}: at '{1}': {2}".format(label, loc, err.message))
    else:
        try:
            jsonschema.validate(instance, schema)
        except Exception as exc:  # noqa: BLE001 - surface any validation failure
            errors.append("{0}: {1}".format(label, exc))
    return errors


def run(script_path):
    # Manual CLI use: `python3 validate_schema.py <file> [...]` validates the
    # given path(s) directly, without a hook payload on stdin.
    if len(sys.argv) > 1:
        file_paths = sys.argv[1:]
    else:
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except Exception:
            payload = {}
        tool_input = payload.get("tool_input") or {}
        file_path = tool_input.get("file_path") or payload.get("file_path") or ""
        if not file_path:
            return 0  # nothing to validate
        file_paths = [file_path]

    rc = 0
    for fp in file_paths:
        rc = max(rc, run_one(script_path, fp))
    return rc


def run_one(script_path, file_path):

    root = project_dir(script_path)
    contracts = os.path.join(root, "contracts")

    abs_path = file_path if os.path.isabs(file_path) else os.path.join(root, file_path)
    abs_path = os.path.abspath(abs_path)

    routed = route(abs_path, root, contracts)
    if routed is None:
        return 0  # not a pipeline artifact
    schema_path, kind, list_keys, expected_version, require_location = routed

    if jsonschema is None:
        _warn("jsonschema not installed; skipping validation of " + os.path.basename(abs_path))
        return 0

    if not os.path.exists(abs_path):
        _warn("target file no longer exists; skipping: " + abs_path)
        return 0
    if not os.path.exists(schema_path):
        _warn("contract not found; skipping: " + schema_path)
        return 0

    # Parse the schema.
    try:
        with open(schema_path, "r", encoding="utf-8") as fh:
            schema = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        _warn("could not read contract {0}: {1}".format(schema_path, exc))
        return 0

    # Parse the written artifact. A parse failure IS a problem worth surfacing.
    try:
        doc, note = load_doc(abs_path)
    except Exception as exc:  # noqa: BLE001 - malformed JSON/YAML in a target file
        _warn("{0} is not parseable: {1}".format(os.path.basename(abs_path), exc))
        return 2
    if note == "yaml_missing":
        _warn("PyYAML not installed; skipping validation of " + os.path.basename(abs_path))
        return 0

    base = os.path.basename(abs_path)
    errors = []
    if kind == "object":
        errors = validate_instance(doc, schema, base)
    elif kind == "array":
        if not isinstance(doc, list):
            errors = ["{0}: expected a JSON array of records, got {1}".format(
                base, type(doc).__name__)]
        else:
            for i, item in enumerate(doc):
                errors.extend(validate_instance(item, schema, "{0}[{1}]".format(base, i)))
    elif kind == "wrapper":
        # {"schema_version": "<ver>", ["location_id": "...",] <key>: [ ...items... ]}
        # Also tolerate a bare top-level array of items.
        if isinstance(doc, list):
            items = doc
        elif isinstance(doc, dict):
            if expected_version and doc.get("schema_version") != expected_version:
                errors.append("{0}: at 'schema_version': must equal '{1}'".format(
                    base, expected_version))
            if require_location and not doc.get("location_id"):
                errors.append("{0}: at 'location_id': required and non-empty".format(base))
            items = None
            for key in list_keys:
                if isinstance(doc.get(key), list):
                    items = doc[key]
                    break
            if items is None:
                errors.append("{0}: missing array under one of {1}".format(base, list_keys))
        else:
            items = None
            errors.append("{0}: expected an object wrapper or array, got {1}".format(
                base, type(doc).__name__))
        if items is not None:
            for i, item in enumerate(items):
                errors.extend(validate_instance(item, schema, "{0}[{1}]".format(base, i)))
    elif kind == "records":
        for i, item in enumerate(extract_records(doc, list_keys)):
            errors.extend(validate_instance(item, schema, "{0}[{1}]".format(base, i)))

    if errors:
        _warn("schema validation FAILED for {0} against {1}:".format(
            base, os.path.basename(schema_path)))
        for line in errors:
            _warn("  - " + line)
        return 2

    return 0


def main():
    try:
        return run(sys.argv[0])
    except Exception as exc:  # noqa: BLE001 - never hard-crash the user's workflow
        _warn("unexpected error, skipping validation: {0}".format(exc))
        return 0


if __name__ == "__main__":
    sys.exit(main())
