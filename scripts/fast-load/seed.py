#!/usr/bin/env python3
"""Seed only the stopped fast-load sandbox databases with identical synthetic rows.

T3 contracts: orchestrationV2.ts:401,1160,1355,1411 (main 5b35402623).
No model turn, provider session, real repository, or real account is involved.
"""
import hashlib
import json
from pathlib import Path
import sqlite3

BASE = Path.home() / "CandyWrapper-research/sandbox/fast-load"
NOW = "2026-10-25T00:00:00.000Z"
THREAD = "fast-load-big-thread"


def insert(db, table, values):
    columns = {row[1] for row in db.execute("PRAGMA table_info(%s)" % table)}
    values = {key: value for key, value in values.items() if key in columns}
    names = list(values)
    db.execute("INSERT OR REPLACE INTO %s (%s) VALUES (%s)" % (
        table, ",".join(names), ",".join("?" for _ in names)), list(values.values()))


def payload(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def seed(name):
    home = BASE / name / "t3home"
    path = home / "userdata/statev2.sqlite"
    assert path.is_relative_to(BASE) and path.is_file()
    db = sqlite3.connect(path)
    workspace = BASE / "project"
    workspace.mkdir(exist_ok=True)
    insert(db, "projection_projects", dict(project_id="fast-load-project", title="Synthetic fast-load project",
        workspace_root=str(workspace), scripts_json="[]", created_at=NOW, updated_at=NOW, deleted_at=None,
        default_model_selection_json=payload({"instanceId": "claude", "provider": "claude", "model": "claude-haiku-5-5"})))
    digest = hashlib.sha256()
    for index in range(81):
        thread_id = THREAD if index == 0 else "fast-load-shell-%03d" % index
        thread = dict(id=thread_id, projectId="fast-load-project", title="Synthetic thread %03d" % index,
            providerInstanceId="claude", defaultProvider="claude",
            modelSelection={"instanceId": "claude", "provider": "claude", "model": "claude-haiku-5-5"},
            runtimeMode="full-access", interactionMode="default", branch=None, worktreePath=None,
            activeProviderThreadId=None, historyOrigin="native",
            lineage=dict(parentThreadId=None, relationshipToParent=None, rootThreadId=thread_id),
            forkedFrom=None, createdAt=NOW, updatedAt=NOW, archivedAt=None, deletedAt=None,
            settledOverride=None, settledAt=None, lastVisitedAt=None, createdBy="user", creationSource="web")
        digest.update(payload(thread).encode())
        insert(db, "orchestration_v2_projection_threads", dict(thread_id=thread_id, project_id="fast-load-project",
            title=thread["title"], default_provider="claude", provider_instance_id="claude", runtime_mode="full-access",
            interaction_mode="default", active_provider_thread_id=None, created_at=NOW, updated_at=NOW,
            archived_at=None, deleted_at=None, payload_json=payload(thread)))
    # 240 user/assistant pairs and 240 command rows. Bodies vary deterministically
    # so gzip has representative repeated prose plus distinct hashes, not one repeated byte.
    for index in range(480):
        role = "user" if index % 2 == 0 else "assistant"
        text = "\n".join("Synthetic benchmark paragraph %04d/%03d: %s. Review the deterministic implementation and record its behavior." %
                         (index, row, hashlib.sha256((str(index) + ":" + str(row)).encode()).hexdigest()) for row in range(48))
        message_id, item_id = "fast-message-%04d" % index, "fast-item-%04d" % index
        message = dict(id=message_id, threadId=THREAD, runId=None, nodeId=None, role=role, text=text,
            attachments=[], streaming=False, createdAt=NOW, updatedAt=NOW, createdBy="user" if role == "user" else "agent",
            creationSource="web" if role == "user" else "provider")
        item = dict(id=item_id, threadId=THREAD, runId=None, nodeId=None, providerThreadId=None,
            providerTurnId=None, nativeItemRef=None, parentItemId=None, ordinal=index * 2, status="completed",
            title=None, startedAt=NOW, completedAt=NOW, updatedAt=NOW, type=role + "_message", messageId=message_id,
            text=text, attachments=[], streaming=False, createdBy=message["createdBy"], creationSource=message["creationSource"])
        if role == "user":
            item["inputIntent"] = "turn_start"
        for value in [message, item]:
            digest.update(payload(value).encode())
        insert(db, "orchestration_v2_projection_messages", dict(message_id=message_id, thread_id=THREAD,
            run_id=None, node_id=None, role=role, streaming=0, created_at=NOW, updated_at=NOW, payload_json=payload(message)))
        insert(db, "orchestration_v2_projection_turn_items", dict(turn_item_id=item_id, thread_id=THREAD,
            run_id=None, node_id=None, provider_thread_id=None, provider_turn_id=None, parent_item_id=None,
            ordinal=index * 2, type=item["type"], status="completed", updated_at=NOW, payload_json=payload(item)))
        insert(db, "orchestration_v2_turn_item_positions", dict(thread_id=THREAD, turn_item_id=item_id, ordinal=index * 2))
        if role == "assistant":
            command_id = "fast-command-%04d" % index
            command = dict(item, id=command_id, type="command_execution", ordinal=index * 2 + 1,
                title="Synthetic command", input="echo synthetic", output="Synthetic command output\n" * 300, exitCode=0)
            for key in ["messageId", "text", "attachments", "streaming", "createdBy", "creationSource"]:
                command.pop(key, None)
            digest.update(payload(command).encode())
            insert(db, "orchestration_v2_projection_turn_items", dict(turn_item_id=command_id, thread_id=THREAD,
                run_id=None, node_id=None, provider_thread_id=None, provider_turn_id=None, parent_item_id=None,
                ordinal=command["ordinal"], type="command_execution", status="completed", updated_at=NOW, payload_json=payload(command)))
            insert(db, "orchestration_v2_turn_item_positions", dict(thread_id=THREAD, turn_item_id=command_id, ordinal=command["ordinal"]))
    db.commit()
    db.close()
    return {"server": name, "sha256": digest.hexdigest(), "threads": 81, "messages": 480, "turn_items": 720}


if __name__ == "__main__":
    for server in ["3473", "main"]:
        print(json.dumps(seed(server), sort_keys=True))
