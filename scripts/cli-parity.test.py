#!/usr/bin/env python3
"""Prove the Action wrapper and direct pinned CLI produce identical artifacts and requests."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN = "short-lived-repository-token"
DEPLOYMENT_ID = "019d0000-0000-7000-8000-000000000001"


class State:
    def __init__(self) -> None:
        self.trace: list[dict[str, Any]] = []
        self.uploads: dict[str, bytes] = {}


def handler_for(state: State):
    class Handler(BaseHTTPRequestHandler):
        server_version = "SproutActionParity/1"

        def log_message(self, _format: str, *_args: object) -> None:
            return

        def body(self) -> bytes:
            return self.rfile.read(int(self.headers.get("Content-Length", "0")))

        def require_token(self) -> None:
            assert self.headers.get("Authorization") == f"Bearer {TOKEN}"

        def respond(self, status: int, document: dict[str, Any]) -> None:
            body = json.dumps(document, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            self.require_token()
            body = self.body()
            document = json.loads(body)
            state.trace.append({"method": "POST", "path": self.path, "json": document})
            if self.path in ("/v1/deploy/upload-url", "/v1/deploy/static-upload-url"):
                digest = document["digest"].removeprefix("sha256:")
                self.respond(
                    200,
                    {
                        "url": f"http://127.0.0.1:{self.server.server_port}/upload/{digest}",
                        "key": f"objects/{digest}",
                    },
                )
            elif self.path == "/v1/deploy/release":
                self.respond(200, {"deployment_id": DEPLOYMENT_ID, "url": None})
            else:
                self.respond(404, {"message": "unexpected endpoint"})

        def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            body = self.body()
            digest = self.path.rsplit("/", 1)[-1]
            assert hashlib.sha256(body).hexdigest() == digest
            content_type = self.headers.get("Content-Type")
            state.uploads[digest] = body
            state.trace.append(
                {
                    "method": "PUT",
                    "path": self.path,
                    "content_type": content_type,
                    "sha256": digest,
                    "bytes": len(body),
                }
            )
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            self.require_token()
            state.trace.append({"method": "GET", "path": self.path})
            assert self.path == f"/v1/deploy/deployments/{DEPLOYMENT_ID}"
            self.respond(
                200,
                {
                    "deployment_id": DEPLOYMENT_ID,
                    "status": "ready",
                    "failure_reason": None,
                    "migration_status": "ready",
                    "migration_output": None,
                    "url": "https://app.example.test",
                },
            )

    return Handler


def inventory(root: pathlib.Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def execute(command: list[str], environment: dict[str, str]) -> tuple[State, str]:
    state = State()
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = environment | {"SPROUTOS_DEPLOY_TOKEN": TOKEN}
    environment["API_URL"] = f"http://127.0.0.1:{server.server_port}"
    command = [value.replace("API_URL", environment["API_URL"]) for value in command]
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert completed.returncode == 0, {
            "command": command,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "trace": state.trace,
        }
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    return state, completed.stdout


def wrapper_environment(temp: pathlib.Path, **values: str) -> dict[str, str]:
    output = temp / "action-output"
    summary = temp / "summary"
    return os.environ.copy() | {
        "GITHUB_OUTPUT": str(output),
        "GITHUB_STEP_SUMMARY": str(summary),
        "PROJECT": "web-app",
        "ENVIRONMENT": "development",  # legacy Action value; CLI maps it explicitly to preview
        "TIMEOUT_SECONDS": "30",
        "COMMIT": "0123456789abcdef0123456789abcdef01234567",
        "REF": "main",
        "MESSAGE": "subject\nbody",
        "RUNTIME": "provided.al2023",
        "HANDLER": "run.sh",
        "MIGRATION_DIRECTORY": "",
        "MIGRATION_HANDLER": "",
        "STATIC_PATHS": "",
        "VERSION_CODE": "",
    } | values


def direct_command(path: pathlib.Path, *, preset: str, extra: list[str]) -> list[str]:
    return [
        "sprout",
        "--json",
        "--api-url",
        "API_URL",
        "deploy",
        "web-app",
        "--path",
        str(path),
        "--preset",
        preset,
        "--environment",
        "development",
        "--timeout-seconds",
        "30",
        "--git-sha",
        "0123456789abcdef0123456789abcdef01234567",
        "--git-ref",
        "main",
        "--message",
        "subject\nbody",
        "--runtime",
        "provided.al2023",
        "--handler",
        "run.sh",
        *extra,
    ]


def without_option(command: list[str], flag: str) -> list[str]:
    index = command.index(flag)
    return command[:index] + command[index + 2 :]


def assert_equal_runs(wrapper: State, direct: State) -> None:
    assert wrapper.trace == direct.trace, (wrapper.trace, direct.trace)
    assert wrapper.uploads == direct.uploads


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sprout-action-parity-") as raw_temp:
        temp = pathlib.Path(raw_temp)
        site = temp / "site"
        migration = temp / "migration"
        static = temp / "static"
        site.mkdir()
        migration.mkdir()
        static.mkdir()
        (site / "run.sh").write_text("#!/bin/sh\nexec ./server\n")
        (site / "server").write_bytes(b"generic-web-binary")
        (site / "run.sh").chmod(0o755)
        (site / "server").chmod(0o755)
        (migration / "migrate.js").write_text("exports.handler = async () => {}\n")
        (static / "app.css").write_text("body { color: green }\n")
        before = inventory(temp)

        wrapper_env = wrapper_environment(
            temp,
            PRESET="web",
            DIRECTORY=str(site),
            MIGRATION_DIRECTORY=str(migration),
            MIGRATION_HANDLER="migrate.handler",
            STATIC_PATHS=f"{static}:assets",
        )
        wrapper, _ = execute(["bash", str(ROOT / "scripts/deploy.sh")], wrapper_env)
        direct, _ = execute(
            direct_command(
                site,
                preset="web",
                extra=[
                    "--migration-path",
                    str(migration),
                    "--migration-handler",
                    "migrate.handler",
                    "--static-path",
                    f"{static}:assets",
                ],
            ),
            os.environ.copy(),
        )
        assert_equal_runs(wrapper, direct)
        assert inventory(temp) == before | {
            "action-output": hashlib.sha256((temp / "action-output").read_bytes()).hexdigest(),
            "summary": hashlib.sha256((temp / "summary").read_bytes()).hexdigest(),
        }

        apk = temp / "app-release.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("classes.dex", b"dex")
        android_env = wrapper_environment(
            temp,
            PRESET="android",
            DIRECTORY=str(apk),
            RUNTIME="",
            HANDLER="",
            VERSION_CODE="42",
        )
        wrapper_android, _ = execute(
            ["bash", str(ROOT / "scripts/deploy.sh")], android_env
        )
        android_command = direct_command(
            apk,
            preset="android",
            extra=["--version-code", "42"],
        )
        android_command = without_option(android_command, "--runtime")
        android_command = without_option(android_command, "--handler")
        direct_android, _ = execute(android_command, os.environ.copy())
        assert_equal_runs(wrapper_android, direct_android)
        uploaded = list(wrapper_android.uploads.values())
        assert uploaded == [apk.read_bytes()], "Android upload was not the raw APK"
        put = next(item for item in wrapper_android.trace if item["method"] == "PUT")
        assert put["content_type"] == "application/vnd.android.package-archive"

    print("released CLI Action/direct request and artifact parity tests passed")


if __name__ == "__main__":
    main()
