#!/usr/bin/env python3
"""Run the real NotchRouter app and CLI with disposable local state."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[4]
EVIDENCE = REPO / ".build/verification/notchrouter"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def process(pid):
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart=,command="],
        capture_output=True, text=True, check=False,
    ).stdout.strip()


def load(run):
    run = Path(run).resolve()
    require(run.parent == EVIDENCE.resolve(), "Run must be under this checkout's evidence directory")
    meta = json.loads((run / "run.json").read_text())
    require(re.fullmatch(r"com\.notchrouter\.verify\.r[0-9a-f]{32}", meta["bundle_id"]),
            "Unexpected disposable preference domain")
    root = Path(meta["root"])
    require(root.parent == Path("/private/tmp") and root.name.startswith("notch-verify-"),
            "Refusing an unexpected disposable root")
    if root.exists():
        require((root / "owner").read_text() == meta["run_id"], "Disposable root ownership mismatch")
    return run, meta


def environment(meta):
    return dict(os.environ, CFFIXED_USER_HOME=meta["home"])


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=4)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def get(meta, route, authenticated=False):
    client = UnixHTTP(str(Path(meta["data"]) / "api.sock"))
    headers = {}
    if authenticated:
        headers["Authorization"] = "Bearer " + (Path(meta["data"]) / "integration-token").read_text().strip()
    try:
        client.request("GET", route, headers=headers)
        response = client.getresponse()
        return response.status, response.read().decode()
    finally:
        client.close()


def doctor(run, meta):
    require(not meta.get("cleaned"), "Run has already been cleaned")
    require(process(meta["pid"]) == meta["process"], "PID/start time/executable no longer match")
    require(meta["executable"] in meta["process"], "Unexpected executable")
    require(digest(meta["executable"]) == meta["app_sha256"], "App changed after launch")
    require(digest(meta["cli"]) == meta["cli_sha256"], "CLI changed after launch")
    require(Path(meta["data"]) == Path(meta["home"]) / "Library/Application Support/NotchRouter",
            "Data directory is not isolated")
    info = plistlib.loads(Path(meta["executable"]).parents[1].joinpath("Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == meta["bundle_id"], "Preference domain mismatch")
    for name, mode in (("", 0o700), ("integration-token", 0o600), ("api.sock", 0o600)):
        target = Path(meta["data"]) / name
        details = target.lstat()
        require(details.st_uid == os.getuid() and stat.S_IMODE(details.st_mode) == mode,
                "Unsafe owner or permissions: " + name)
        require(not target.is_symlink(), "Unexpected symlink: " + name)
    require(stat.S_ISSOCK((Path(meta["data"]) / "api.sock").stat().st_mode), "Missing Unix socket")
    require(len((Path(meta["data"]) / "integration-token").read_text().strip()) >= 32, "Invalid token")
    sockets = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(meta["pid"]), "-U", "-Fn"],
                             capture_output=True, text=True).stdout
    require(str(Path(meta["data"]) / "api.sock") in sockets, "Socket is not owned by this app PID")
    tcp = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(meta["pid"]), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                         capture_output=True, text=True)
    require(tcp.returncode == 1 and not tcp.stdout, "App has a TCP listener or port check failed")
    status, body = get(meta, "/v1/health")
    require(status == 200 and json.loads(body) == {"status": "ok"}, "Health check failed")
    denied, _ = get(meta, "/v1/activities")
    accepted, body = get(meta, "/v1/activities", True)
    require(denied == 401 and accepted == 200 and isinstance(json.loads(body), list), "Authentication check failed")
    result = {"pid": meta["pid"], "bundle_id": meta["bundle_id"], "data": meta["data"],
              "app_sha256": meta["app_sha256"], "cli_sha256": meta["cli_sha256"],
              "tcp_listeners": [], "health": "ok", "unauthenticated_status": denied,
              "authenticated_status": accepted}
    save(run / "doctor.json", result)
    return result


def cli(run, meta, arguments):
    require(arguments and arguments[0] in {"health", "list", "send", "demo", "help", "--help"},
            "Only health/list/send/demo/help are supported; installers and token output are excluded")
    doctor(run, meta)
    result = subprocess.run([meta["cli"], *arguments], env=environment(meta),
                            capture_output=True, text=True, timeout=15)
    with (run / "commands.jsonl").open("a") as output:
        output.write(json.dumps({"entry_point": "notchctl", "argv": arguments,
                                 "stdout": result.stdout, "stderr": result.stderr,
                                 "exit_code": result.returncode}) + "\n")
    return result


def cleanup(run, meta):
    if meta.get("cleaned"):
        return
    if meta.get("pid") and process(meta["pid"]):
        require(process(meta["pid"]) == meta["process"], "Refusing to signal a replaced PID")
        os.kill(meta["pid"], signal.SIGTERM)
        for _ in range(50):
            try:
                os.waitpid(meta["pid"], os.WNOHANG)
            except ChildProcessError:
                pass
            if not process(meta["pid"]):
                break
            time.sleep(0.1)
        require(not process(meta["pid"]), "App did not exit; retain state and inspect this PID")
    root = Path(meta["root"])
    if root.exists():
        require((root / "owner").read_text() == meta["run_id"], "Refusing to remove unowned state")
        # cfprefsd persists the unique bundle domain in the account's Preferences
        # directory even when Foundation's home is redirected. Delete only ours.
        require(re.fullmatch(r"com\.notchrouter\.verify\.r[0-9a-f]{32}", meta["bundle_id"]),
                "Refusing to remove an unexpected preference domain")
        existing = subprocess.run(["/usr/bin/defaults", "export", meta["bundle_id"], "-"],
                                  capture_output=True)
        if existing.returncode == 0 and plistlib.loads(existing.stdout):
            subprocess.run(["/usr/bin/defaults", "delete", meta["bundle_id"]],
                           capture_output=True, check=True)
        remaining = subprocess.run(["/usr/bin/defaults", "export", meta["bundle_id"], "-"],
                                   capture_output=True)
        require(remaining.returncode != 0 or plistlib.loads(remaining.stdout) == {},
                "Disposable preferences remain; retain state for inspection")
        # defaults may leave an empty plist after clearing the cached domain.
        preference_file = Path.home() / "Library/Preferences" / (meta["bundle_id"] + ".plist")
        if preference_file.exists():
            require(plistlib.loads(preference_file.read_bytes()) == {}, "Preference file is not empty")
            preference_file.unlink()
        shutil.rmtree(root)
    meta["cleaned"] = True
    save(run / "run.json", meta)
    save(run / "cleanup.json", {"process_stopped": True, "disposable_root_removed": not root.exists(),
                                "disposable_preferences_removed": True,
                                "evidence_retained": sorted(p.name for p in run.iterdir())})


def launch():
    run_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    run = EVIDENCE / run_id
    run.mkdir(parents=True, mode=0o700)
    print(run, flush=True)
    with (run / "build.log").open("w") as output:
        subprocess.run(["swift", "build"], cwd=REPO, stdout=output, stderr=subprocess.STDOUT, check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=REPO, text=True).strip())
    root = Path(tempfile.mkdtemp(prefix="notch-verify-", dir="/tmp")).resolve()
    (root / "owner").write_text(run_id)
    # Foundation canonicalizes /private/tmp to /tmp when resolving user paths.
    home = Path("/tmp") / root.name / "home"
    home.mkdir(mode=0o700)
    app = root / "NotchRouter Verification.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir()
    executable = macos / "NotchRouter"
    cli_path = root / "notchctl"
    meta = {"run_id": run_id, "root": str(root), "home": str(home), "app": str(app),
            "executable": str(executable), "cli": str(cli_path),
            "data": str(home / "Library/Application Support/NotchRouter"),
            "bundle_id": "com.notchrouter.verify.r" + uuid.uuid4().hex}
    save(run / "run.json", meta)
    try:
        shutil.copy2(binary_dir / "NotchRouter", executable)
        shutil.copy2(binary_dir / "notchctl", cli_path)
        (frameworks / "Sparkle.framework").symlink_to(binary_dir / "Sparkle.framework", target_is_directory=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": meta["bundle_id"], "CFBundleName": "NotchRouter Verification",
            "CFBundleExecutable": "NotchRouter", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "0.0.0",
            "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
        }))
        # Verify Foundation behavior before allowing the real app to resolve paths.
        probe = subprocess.run(["swift", "-e", 'import Foundation; print(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)'],
                               env=environment(meta), capture_output=True, text=True, check=True)
        require(probe.stdout.strip() == str(home / "Library/Application Support"), "Foundation home isolation failed")
        (run / "isolation.txt").write_text(probe.stdout)
        meta.update(app_sha256=digest(executable), cli_sha256=digest(cli_path))
        # Argument-domain values override inherited preferences. This is a real app,
        # with only optional integrations and network listeners held off.
        flags = ["legacyTCPAPIEnabled", "clipboardHistoryEnabled", "musicIntegrationEnabled",
                 "systemNotificationsEnabled", "focusCompletionNotificationsEnabled",
                 "focusCompletionSoundEnabled", "crashReportingEnabled"]
        with (run / "app.log").open("w") as output:
            child = subprocess.Popen([str(executable), *sum((["-" + key, "NO"] for key in flags), [])],
                                     env=environment(meta), stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        meta.update(pid=child.pid, process=process(child.pid))
        save(run / "run.json", meta)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            require(child.poll() is None, "App exited before readiness; see app.log")
            try:
                doctor(run, meta)
                print("Ready. Isolated bundle: " + meta["bundle_id"], file=sys.stderr, flush=True)
                return
            except (OSError, RuntimeError):
                time.sleep(0.2)
        raise RuntimeError("App did not become ready; see app.log")
    except BaseException:
        cleanup(run, meta)
        raise


def proof(run, meta):
    doctor(run, meta)
    activity_id = "verification-" + meta["run_id"]
    for state, progress, message in (("running", "0.25", "Checking the isolated app"),
                                     ("succeeded", "1", "Verification finished")):
        result = cli(run, meta, ["send", "--id", activity_id, "--source", "Verification Agent",
                                "--title", "Verify isolated activity", "--state", state,
                                "--message", message, "--progress", progress])
        require(result.returncode == 0, "Send failed: " + result.stderr)
        result = cli(run, meta, ["list"])
        require(result.returncode == 0, "List failed: " + result.stderr)
        activities = json.loads(result.stdout)
        matching = [a for a in activities if a["id"] == activity_id]
        require(len(matching) == 1 and matching[0]["state"] == state, "List did not reflect the update")
        save(run / ("activities-" + state + ".json"), activities)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                stored = json.loads((Path(meta["data"]) / "activities.json").read_text())
                record = next(a for a in stored if a["id"] == activity_id)
                if record["state"] == state and record["message"] == message:
                    save(run / ("persisted-" + state + ".json"), stored)
                    break
            except (OSError, ValueError, StopIteration):
                pass
            time.sleep(0.1)
        else:
            raise RuntimeError("Persisted activity did not match the CLI update")
    save(run / "proof.json", {"feature": "activity.publish-update", "entry_point": "notchctl send",
                              "states": ["running", "succeeded"], "same_id_updated": True,
                              "second_view": "activities.json", "desktop_ui_verified": False})
    print("PASS: CLI publish/update, authenticated list, and persisted activity")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["launch", "doctor", "cli", "proof", "cleanup"])
    parser.add_argument("run", nargs="?")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == "launch":
        launch()
        return
    require(args.run, "Supply the evidence directory printed by launch")
    run, meta = load(args.run)
    if args.command == "doctor":
        print(json.dumps(doctor(run, meta), indent=2))
    elif args.command == "cli":
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        result = cli(run, meta, arguments)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        sys.exit(result.returncode)
    elif args.command == "proof":
        proof(run, meta)
    else:
        cleanup(run, meta)
        print("Cleaned disposable process and state; evidence remains at " + str(run))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("verify-notchrouter: " + str(error), file=sys.stderr)
        sys.exit(1)
