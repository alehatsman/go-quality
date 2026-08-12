#!/usr/bin/env bash
# findings-to-sarif — project the JSONL findings stream (.gate/findings.jsonl,
# the goq/findings artifact) into SARIF 2.1.0 on stdout (dex #155 P2).
#
# A pure, leaf projection: no analysis of its own, just a format change so the
# same findings upload to GitHub code scanning and render in IDEs. The finding
# schema's levels (error|warning|note) already match SARIF's, and its
# fingerprint becomes a SARIF partialFingerprint for stable cross-run dedup.
#
# Usage: findings-to-sarif.sh [<findings.jsonl>]   # default .gate/findings.jsonl
set -euo pipefail

IN="${1:-.gate/findings.jsonl}"
if [ ! -f "$IN" ]; then
  # No findings artifact → emit a valid empty SARIF run rather than failing, so
  # this is safe to wire unconditionally in CI.
  IN=""
fi

IN="$IN" python3 - <<'PY'
import json, os, sys

inp = os.environ.get("IN", "")
results, rules = [], {}
if inp:
    for line in open(inp):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue  # tolerate a malformed line rather than sink the run
        tool = o.get("tool", "gate")
        rule = o.get("rule", "finding")
        rid = f"{tool}/{rule}"
        rules.setdefault(rid, {"id": rid, "name": rule, "properties": {"tool": tool}})
        region = {"startLine": max(1, int(o.get("line") or 1))}
        if o.get("col"):
            region["startColumn"] = int(o["col"])
        res = {
            "ruleId": rid,
            "level": o.get("level", "warning"),  # error|warning|note match SARIF
            "message": {"text": o.get("message", "")},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": o.get("path", "")},
                    "region": region,
                }
            }],
        }
        if o.get("fingerprint"):
            res["partialFingerprints"] = {"dexGate/v1": o["fingerprint"]}
        results.append(res)

sarif = {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "version": "2.1.0",
    "runs": [{
        "tool": {"driver": {
            "name": "dex-gate",
            "informationUri": "https://github.com/alehatsman/go-quality",
            "rules": list(rules.values()),
        }},
        "results": results,
    }],
}
json.dump(sarif, sys.stdout, indent=2)
print()
PY
