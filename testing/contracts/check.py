#!/usr/bin/env python3
"""Contract checks exercise generators and effective normalization semantics."""
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import jsonschema

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "lib" / f"{name}.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


lock = json.loads((ROOT / "testing/contracts/ai-first.lock.json").read_text())
for name, digest in lock["files"].items():
    assert hashlib.sha256((ROOT / "testing/contracts" / name).read_bytes()).hexdigest() == digest
schema = json.loads((ROOT / "testing/contracts/ai-first-1.0.0-manifest.schema.json").read_text())
snapshot = json.loads(Path(sys.argv[1]).read_text())
publication = module("ai_catalog").publication(snapshot, (ROOT / "VERSION").read_text().strip())
jsonschema.Draft202012Validator(schema).validate(publication)
assert publication["items"]
assert len({item["id"] for item in publication["items"]}) == len(publication["items"])
assert all(item["capability"]["effects"] == "read" for item in publication["items"])

normalize = module("fpm_normalize").normalize
fixture = """[test]
request_terminate_timeout = 120s
; simai-site-perf-begin
request_terminate_timeout = 300s
; simai-site-perf-end
; simai-site-ini-begin
php_admin_value[max_execution_time] = 180
php_admin_flag[short_open_tag] = off
; simai-site-ini-end
; simai-profile-ini-begin
php_admin_value[max_execution_time] = 300
php_admin_flag[short_open_tag] = on
; simai-profile-ini-end
"""
out = normalize(fixture)
assert out.count("request_terminate_timeout =") == 1 and "= 300s" in out
assert out.count("php_admin_value[max_execution_time]") == 1 and "= 180" in out
assert out.count("php_admin_flag[short_open_tag]") == 1 and "= off" in out
assert normalize(out) == out
print("PASS AI First 1.0.0 schema, immutable pin, registry binding and FPM precedence/idempotence")
