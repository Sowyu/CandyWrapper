#!/usr/bin/env python3
"""Validate a completed matrix and print small, scrubbed summary JSON."""
import argparse
import json
from pathlib import Path
import statistics


def span(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def summarize(path):
    values = [json.loads(line) for line in Path(path).read_text().splitlines()]
    for server in ["3473", "main"]:
        for phase in ["cold", "history-validation"]:
            group = [value for value in values if value["server"] == server and value["phase"] == phase]
            assert len(group) == 6, "Expected three runs per client"
            assert len({value["content"]["sha256"] for value in group}) == 1, "Client-visible content changed"
    assert {value["content"]["full_visible_message_sha256"] for value in values if value["phase"] == "history-validation"} == {
        "f483653408b8fefcf4508bbc0e59aab6b48b2206c69d786b3c4c59afc7b4f9f6"}
    cells = []
    for server in ["3473", "main"]:
        for client in ["old", "new"]:
            group = [value for value in values if value["server"] == server and value["client"] == client]
            cell = {"server": server, "client": client, "client_commit": group[0]["client_commit"], "stages": {}}
            for phase in ["cold", "retained-reconnect"]:
                runs = [value for value in group if value["phase"] == phase]
                assert len(runs) == 3 and all(value["synchronized"] and value["failure"] is None for value in runs)
                cell["stages"][phase] = {
                    "protocol_seconds": span([value["seconds"] for value in runs]),
                    "both_projections_seconds": span([max(value["first_projection_seconds"], value["shell_projection_seconds"]) for value in runs]),
                    "thread_projection_seconds": span([value["first_projection_seconds"] for value in runs]),
                    "shell_projection_seconds": span([value["shell_projection_seconds"] for value in runs]),
                    "wire_bytes": {key: span([value["wire_bytes"][key] for value in runs]) for key in runs[0]["wire_bytes"]},
                    "shell_threads": sorted({value["shell_threads"] for value in runs}),
                    "initial_visible_items": sorted({value["content"]["visible_items"] for value in runs})}
            pages = [value for value in group if value["phase"] == "history-validation"]
            assert all(value["content"]["visible_message_items"] == 482 and value["content"]["visible_items"] == 1322
                       and value["content"]["blank_visible_message_items"] == 0 for value in pages)
            cell["history"] = {"pages": sorted({value["pages"] for value in pages}),
                               "visible_items": 1322, "visible_messages": 482, "blank_messages": 0}
            cells.append(cell)
    return {"rounds": 3, "main_sha": "5b35402623d7d1d88eaa472807272a6c2e78012a",
            "downstream_kbps": 400, "upstream_kbps": 400, "rtt_ms": 400, "cells": cells}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matrix")
    args = parser.parse_args()
    print(json.dumps(summarize(args.matrix), sort_keys=True, indent=2))
