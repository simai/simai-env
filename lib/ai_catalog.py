#!/usr/bin/env python3
"""Generate AI First 1.0 from the live command registry snapshot."""
import hashlib
import json
import sys


PILOT = {"self describe", "site describe", "self commands", "site doctor", "site list", "ssl status", "db status"}


def publication(snapshot, version):
    items = []
    for command in snapshot["commands"]:
        operation = command["command"].removeprefix("simai-admin.sh ")
        if operation not in PILOT or command["effects"] != "read":
            continue
        items.append({
            "id": "urn:simai:env:command:" + operation.replace(" ", ":"),
            "kind": "capability", "title": operation,
            "description": command["description"], "language": "en",
            "revision": version, "status": "published", "source": "commands.json",
            "representations": [{"href": "commands.json", "mediaType": "application/json", "role": "full"}],
            "appliesTo": {"product": "urn:simai:env", "versions": [version]},
            "capability": {
                "contract": {"type": "external", "href": "commands.json", "mediaType": "application/json",
                             "operation": command["command"], "description": "Find the exact command in the commands array of simai-commands/1."},
                "effects": "read", "authorization": "required", "confirmation": "not-required",
                "instructions": "docs/architecture/command-execution.md",
            },
        })
    return {
        "format": "ai-first", "formatVersion": "1.0", "document": "manifest",
        "revision": version, "requires": ["capability"],
        "resource": {"id": "urn:simai:env", "name": "simai-env",
                     "description": "Authorized root CLI discovery; read-only pilot.",
                     "language": "en", "scope": "./", "publisher": {"name": "SIMAI"}},
        "items": items,
        "x-simai-contract-digest": hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest(),
        "x-simai-standard": {"version": "1.0.0", "commit": "8ed3d48efdb2435f1dd4142ab3339b00f5340fb1"},
    }


if __name__ == "__main__":
    json.dump(publication(json.load(sys.stdin), sys.argv[1]), sys.stdout, indent=2)
    print()
