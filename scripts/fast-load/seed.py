#!/usr/bin/env python3
"""Seed only the stopped fast-load sandbox databases with identical synthetic rows.

T3 contracts: orchestrationV2.ts:401,1160,1355,1411 (main 5b35402623).
No model turn, provider session, real repository, or real account is involved.
"""
import datetime
import hashlib
import json
from pathlib import Path
import sqlite3
import argparse
import subprocess

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


def add_item(db, digest, item):
    digest.update(payload(item).encode())
    insert(db, "orchestration_v2_projection_turn_items", dict(turn_item_id=item["id"], thread_id=item["threadId"],
        run_id=item["runId"], node_id=item["nodeId"], provider_thread_id=item["providerThreadId"],
        provider_turn_id=item["providerTurnId"], parent_item_id=None, ordinal=item["ordinal"],
        type=item["type"], status=item["status"], updated_at=NOW, payload_json=payload(item)))
    insert(db, "orchestration_v2_turn_item_positions", dict(thread_id=item["threadId"], turn_item_id=item["id"], ordinal=item["ordinal"]))


def add_run(db, digest, thread_id, prefix, status):
    run_id, node_id, provider_thread, provider_turn = [prefix+suffix for suffix in ["-run", "-node", "-provider-thread", "-provider-turn"]]
    attempt_id = prefix+"-attempt"
    completed = NOW if status == "completed" else None
    run = dict(id=run_id, threadId=thread_id, ordinal=1, providerInstanceId="claude", provider="claude",
        modelSelection={"instanceId":"claude","provider":"claude","model":"claude-haiku-5-5"},
        providerThreadId=provider_thread, userMessageId="fast-message-0480", rootNodeId=node_id,
        activeAttemptId=attempt_id, status=status, requestedAt=NOW, startedAt=NOW, completedAt=completed,
        checkpointId=None, contextHandoffId=None)
    node = dict(id=node_id, threadId=thread_id, runId=run_id, parentNodeId=None, rootNodeId=node_id,
        kind="root_turn", status=status, countsForRun=True, providerThreadId=provider_thread,
        providerTurnId=provider_turn, nativeItemRef=None, runtimeRequestId=None, checkpointScopeId=None,
        startedAt=NOW, completedAt=completed)
    attempt = dict(id=attempt_id, runId=run_id, attemptOrdinal=1, rootNodeId=node_id,
        providerInstanceId="claude", provider="claude", providerThreadId=provider_thread,
        providerTurnId=provider_turn, reason="initial", status=status, startedAt=NOW, completedAt=completed)
    for value in [run,node,attempt]: digest.update(payload(value).encode())
    insert(db,"orchestration_v2_projection_runs",dict(run_id=run_id,thread_id=thread_id,ordinal=1,
        provider="claude",provider_instance_id="claude",provider_thread_id=provider_thread,status=status,
        requested_at=NOW,completed_at=completed,payload_json=payload(run)))
    insert(db,"orchestration_v2_projection_nodes",dict(node_id=node_id,thread_id=thread_id,run_id=run_id,
        parent_node_id=None,root_node_id=node_id,kind="root_turn",status=status,
        provider_thread_id=provider_thread,provider_turn_id=provider_turn,runtime_request_id=None,
        checkpoint_scope_id=None,started_at=NOW,completed_at=completed,payload_json=payload(node)))
    insert(db,"orchestration_v2_projection_run_attempts",dict(attempt_id=attempt_id,thread_id=thread_id,
        run_id=run_id,attempt_ordinal=1,root_node_id=node_id,provider="claude",provider_instance_id="claude",
        provider_thread_id=provider_thread,provider_turn_id=provider_turn,status=status,payload_json=payload(attempt)))
    return run_id,node_id,provider_thread,provider_turn


def seed(name):
    home = BASE / name / "t3home"
    path = home / "userdata/statev2.sqlite"
    assert path.resolve().is_relative_to(BASE.resolve()) and path.is_file()
    pidfile = BASE / name / "server.pid"
    if pidfile.exists():
        command = subprocess.run(["ps", "-p", pidfile.read_text().strip(), "-o", "command="],
                                 capture_output=True, text=True).stdout
        if str(home) in command:
            raise RuntimeError("Stop the fast-load server before replacing its fixture")
    db = sqlite3.connect(path)
    workspace = BASE / "project"
    workspace.mkdir(exist_ok=True)
    insert(db, "projection_projects", dict(project_id="fast-load-project", title="Synthetic fast-load project",
        workspace_root=str(workspace), scripts_json="[]", created_at=NOW, updated_at=NOW, deleted_at=None,
        default_model_selection_json=payload({"instanceId": "claude", "provider": "claude", "model": "claude-haiku-5-5"})))
    digest = hashlib.sha256()
    for index in range(1301):
        thread_id = THREAD if index == 0 else "fast-load-shell-%03d" % index
        thread = dict(id=thread_id, projectId="fast-load-project", title="Synthetic thread %03d" % index,
            providerInstanceId="claude", defaultProvider="claude",
            modelSelection={"instanceId": "claude", "provider": "claude", "model": "claude-haiku-5-5"},
            runtimeMode="full-access", interactionMode="default", branch=None, worktreePath=None,
            activeProviderThreadId=None, historyOrigin="native",
            lineage=dict(parentThreadId=None, relationshipToParent=None, rootThreadId=thread_id),
            forkedFrom=None, createdAt=NOW, updatedAt=NOW, archivedAt=None, deletedAt=None,
            settledOverride=None, settledAt=None, lastVisitedAt=None, createdBy="user", creationSource="web")
        if 81 <= index < 1081:
            settled = (datetime.datetime(2025, 1, 1) + datetime.timedelta(minutes=index)).isoformat(timespec="milliseconds") + "Z"
            thread.update(settledOverride="settled", settledAt=settled, createdAt=settled, updatedAt=settled)
        elif index >= 1081:
            thread["lineage"] = dict(parentThreadId=THREAD, relationshipToParent="subagent", rootThreadId=THREAD)
            thread.update(createdBy="agent", creationSource="provider")
        digest.update(payload(thread).encode())
        insert(db, "orchestration_v2_projection_threads", dict(thread_id=thread_id, project_id="fast-load-project",
            title=thread["title"], default_provider="claude", provider_instance_id="claude", runtime_mode="full-access",
            interaction_mode="default", active_provider_thread_id=None, created_at=thread["createdAt"], updated_at=thread["updatedAt"],
            archived_at=None, deleted_at=None, payload_json=payload(thread)))
        if index >= 1281:
            # Twenty active child threads remain visible when idle children are omitted.
            add_run(db, digest, thread_id, "fast-live-%04d" % index, "running")
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
    # A final agent-driven run has no intervening user rows. The old bounded
    # policy includes the long turn; main's agent window stops at 75 rows.
    run_id, node_id, provider_thread, provider_turn = add_run(db, digest, THREAD, "fast-long-run", "completed")
    for role, ordinal in [("user", 1000), ("assistant", 1701)]:
        message_id = "fast-message-0480" if role == "user" else "fast-message-0481"
        item_id = "fast-final-user" if role == "user" else "fast-final-answer"
        text = "Inspect the synthetic implementation and report its behavior." if role == "user" else "The synthetic long run completed. Every source message must survive history paging."
        message = dict(id=message_id, threadId=THREAD, runId=run_id, nodeId=node_id, role=role,
            text=text, attachments=[], streaming=False, createdAt=NOW, updatedAt=NOW,
            createdBy="agent", creationSource="mcp")
        item = dict(id=item_id, threadId=THREAD, runId=run_id, nodeId=node_id,
            providerThreadId=provider_thread, providerTurnId=provider_turn, nativeItemRef=None,
            parentItemId=None, ordinal=ordinal, status="completed", title=None,
            startedAt=NOW, completedAt=NOW, updatedAt=NOW, type=role+"_message",
            messageId=message_id, text=text, attachments=[], streaming=False,
            createdBy="agent", creationSource="mcp", inputIntent="turn_start")
        digest.update(payload(message).encode())
        insert(db, "orchestration_v2_projection_messages", dict(message_id=message_id, thread_id=THREAD,
            run_id=run_id, node_id=node_id, role=role, streaming=0, created_at=NOW, updated_at=NOW,
            payload_json=payload(message)))
        add_item(db, digest, item)
    for index in range(600):
        item = dict(id="fast-long-tool-%04d" % index, threadId=THREAD, runId=run_id, nodeId=node_id,
            providerThreadId=provider_thread, providerTurnId=provider_turn, nativeItemRef=None,
            parentItemId=None, ordinal=1001+index, status="completed", title="Synthetic inspection %04d" % index,
            startedAt=NOW, completedAt=NOW, updatedAt=NOW)
        if index % 3 == 0:
            item.update(type="reasoning", streaming=False, text="\n".join(
                "Inspect section %04d/%03d with digest %s before the next step." %
                (index, row, hashlib.sha256(("tool:%d:%d" % (index,row)).encode()).hexdigest())
                for row in range(32)))
        else:
            item.update(type="command_execution", input="cat synthetic-source-%04d.swift # %s" %
                (index, hashlib.sha256(str(index).encode()).hexdigest()),
                output="Synthetic successful output\n"*300, exitCode=0)
        add_item(db, digest, item)
    expected = hashlib.sha256()
    for message_id, raw in db.execute("SELECT message_id,payload_json FROM orchestration_v2_projection_messages WHERE thread_id=? ORDER BY message_id", (THREAD,)):
        expected.update((message_id+"\0"+json.loads(raw)["text"]+"\0").encode())
    db.commit()
    db.close()
    return {"server": name, "sha256": digest.hexdigest(), "threads": 1301,
            "old_settled": 1000, "idle_children": 200, "live_children": 20,
            "messages": 482, "turn_items": 1322, "long_run_tool_rows": 600,
            "full_visible_message_sha256": expected.hexdigest()}


def activate(name):
    # Startup reconciliation terminalizes running rows. Restore only synthetic
    # read-model rows after readiness, without a command/event/outbox entry, so
    # no provider work can start. Shell reads still exercise live-child retention.
    db = sqlite3.connect(BASE / name / "t3home/userdata/statev2.sqlite")
    for table, id_column in [("orchestration_v2_projection_runs", "run_id"),
                             ("orchestration_v2_projection_run_attempts", "attempt_id"),
                             ("orchestration_v2_projection_nodes", "node_id")]:
        rows = list(db.execute("SELECT %s,payload_json FROM %s WHERE %s LIKE 'fast-live-%%'" % (id_column, table, id_column)))
        for row_id, raw in rows:
            value = json.loads(raw)
            value.update(status="running", completedAt=None)
            columns = {row[1] for row in db.execute("PRAGMA table_info(%s)" % table)}
            extra = ",completed_at=NULL" if "completed_at" in columns else ""
            db.execute("UPDATE %s SET status='running',payload_json=?%s WHERE %s=?" % (table, extra, id_column),
                       (payload(value), row_id))
    db.commit()
    db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--activate", action="store_true")
    args = parser.parse_args()
    for server in ["3473", "main"]:
        if args.activate:
            activate(server)
            print("activated synthetic read-model children", server)
        else:
            print(json.dumps(seed(server), sort_keys=True))
