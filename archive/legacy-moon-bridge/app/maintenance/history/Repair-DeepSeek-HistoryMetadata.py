#!/usr/bin/env python3
"""Repair blank Codex sidebar metadata without changing rollout history."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import sqlite3
import sys
from typing import Any


def compact_text(text: str) -> str:
    request = re.search(
        r"(?is)##\s+My request for Codex:\s*(.*)$",
        text,
    )
    if request:
        text = request.group(1)
    text = re.sub(
        r"(?is)<(?:recommended_plugins|environment_context|"
        r"in-app-browser-context)\b.*?</(?:recommended_plugins|"
        r"environment_context|in-app-browser-context)>",
        " ",
        text,
    )
    text = re.sub(
        r"(?im)^\s*#\s*Files mentioned by the user:\s*$",
        " ",
        text,
    )
    return re.sub(r"\s+", " ", text).strip()


def shorten(text: str, maximum: int = 92) -> str:
    if len(text) <= maximum:
        return text
    short = text[: maximum - 3].rstrip()
    boundary = short.rfind(" ")
    if boundary >= 48:
        short = short[:boundary]
    return short + "..."


def model_label(model: str) -> str:
    if model == "deepseek-v4-flash-vision-exp":
        return "DeepSeek V4 Flash Vision"
    if model == "deepseek-v4-flash":
        return "DeepSeek V4 Flash"
    return "DeepSeek V4 Pro"


def read_rollout(path: pathlib.Path) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    model = ""
    user_message = ""
    with path.open("r", encoding="utf-8") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue
            payload = record.get("payload") or {}
            if record.get("type") == "session_meta":
                metadata = payload
            elif record.get("type") == "turn_context" and not model:
                model = str(payload.get("model") or "")
            elif (
                record.get("type") == "event_msg"
                and payload.get("type") == "user_message"
            ):
                user_message = str(payload.get("message") or "")
                break
    return {
        "metadata": metadata,
        "model": model or "deepseek-v4-pro",
        "user_message": user_message,
    }


def fallback_title(
    rollout: dict[str, Any],
    rollout_path: pathlib.Path,
) -> str:
    metadata = rollout["metadata"]
    summary = compact_text(rollout["user_message"])
    if not summary:
        cwd = pathlib.Path(str(metadata.get("cwd") or ""))
        workspace = cwd.name or "coding task"
        if (
            workspace.lower() in {"pro", "flash"}
            and "DeepSeek-Acceptance-Runs" in str(cwd)
        ):
            workspace = "acceptance test"
        timestamp = metadata.get("timestamp")
        local_stamp = ""
        if timestamp:
            try:
                parsed = dt.datetime.fromisoformat(
                    str(timestamp).replace("Z", "+00:00")
                )
                local_stamp = parsed.astimezone().strftime("%Y-%m-%d %H:%M")
            except ValueError:
                local_stamp = ""
        summary = (
            f"{workspace} ({local_stamp})"
            if local_stamp
            else workspace
        )
    return shorten(f"{model_label(rollout['model'])}: {summary}")


def integrity_check(connection: sqlite3.Connection) -> None:
    result = connection.execute("PRAGMA integrity_check").fetchone()
    if not result or result[0] != "ok":
        raise RuntimeError(f"SQLite integrity check failed: {result!r}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--codex-home",
        type=pathlib.Path,
        required=True,
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Commit the narrow metadata update.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    codex_home = arguments.codex_home.resolve()
    database = codex_home / "state_5.sqlite"
    if not database.is_file():
        raise FileNotFoundError(database)

    connection = sqlite3.connect(database, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 10000")
    try:
        integrity_check(connection)
        rows = connection.execute(
            """
            SELECT
                id,
                rollout_path,
                title,
                first_user_message,
                preview,
                has_user_event,
                source,
                model_provider,
                thread_source,
                archived
            FROM threads
            WHERE model_provider = 'moonbridge'
              AND thread_source = 'user'
              AND archived = 0
              AND source IN ('vscode', 'appServer')
              AND (
                    COALESCE(first_user_message, '') = ''
                 OR COALESCE(preview, '') = ''
                 OR has_user_event = 0
              )
            ORDER BY created_at
            """
        ).fetchall()

        repairs: list[dict[str, str]] = []
        for row in rows:
            rollout_path = pathlib.Path(row["rollout_path"])
            if not rollout_path.is_file():
                raise FileNotFoundError(
                    f"Missing rollout for task {row['id']}: {rollout_path}"
                )
            rollout = read_rollout(rollout_path)
            metadata = rollout["metadata"]
            if str(metadata.get("id") or "") != row["id"]:
                raise RuntimeError(
                    f"Rollout ID mismatch for task {row['id']}"
                )
            if str(metadata.get("model_provider") or "") != "moonbridge":
                raise RuntimeError(
                    f"Rollout provider mismatch for task {row['id']}"
                )

            title = str(row["title"] or "").strip()
            if not title:
                title = fallback_title(rollout, rollout_path)
            raw_message = str(rollout["user_message"] or "").strip()
            first_user_message = raw_message or title
            preview = compact_text(raw_message) or title
            preview = shorten(preview, 240)
            repairs.append(
                {
                    "id": row["id"],
                    "title": title,
                    "first_user_message": first_user_message,
                    "preview": preview,
                }
            )

        if arguments.apply and repairs:
            connection.execute("BEGIN IMMEDIATE")
            try:
                for repair in repairs:
                    cursor = connection.execute(
                        """
                        UPDATE threads
                        SET
                            title = CASE
                                WHEN COALESCE(title, '') = '' THEN ?
                                ELSE title
                            END,
                            first_user_message = CASE
                                WHEN COALESCE(first_user_message, '') = ''
                                THEN ?
                                ELSE first_user_message
                            END,
                            preview = CASE
                                WHEN COALESCE(preview, '') = '' THEN ?
                                ELSE preview
                            END,
                            has_user_event = 1
                        WHERE id = ?
                          AND model_provider = 'moonbridge'
                          AND thread_source = 'user'
                          AND archived = 0
                          AND source IN ('vscode', 'appServer')
                          AND (
                                COALESCE(first_user_message, '') = ''
                             OR COALESCE(preview, '') = ''
                             OR has_user_event = 0
                          )
                        """,
                        (
                            repair["title"],
                            repair["first_user_message"],
                            repair["preview"],
                            repair["id"],
                        ),
                    )
                    if cursor.rowcount != 1:
                        raise RuntimeError(
                            "Concurrent metadata change detected for task "
                            + repair["id"]
                        )
                connection.commit()
            except Exception:
                connection.rollback()
                raise
            integrity_check(connection)

        print(
            json.dumps(
                {
                    "status": "ok",
                    "apply": arguments.apply,
                    "candidate_count": len(repairs),
                    "task_ids": [repair["id"] for repair in repairs],
                    "integrity": "ok",
                },
                ensure_ascii=True,
            )
        )
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(
            json.dumps(
                {
                    "status": "error",
                    "error_type": type(error).__name__,
                    "message": str(error),
                },
                ensure_ascii=True,
            ),
            file=sys.stderr,
        )
        raise SystemExit(1)
