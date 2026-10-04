#!/usr/bin/env python3
"""Prepare isolated, genuinely signed production launch agents without FDA.

Run prepare, select the printed fixture directory in the native picker, then run
verify. Optionally run replace and reselect before verify to test root replacement. Names, signing identifiers, preferences, and cache locations are unique;
the installed EverythingMac and its permissions remain untouched.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
STATE = Path(tempfile.gettempdir()) / "everythingmac-scope-smoke-state.json"


def run(arguments, **kwargs):
    return subprocess.run([str(a) for a in arguments], check=True, **kwargs)


def client(state, operation, text=""):
    output = Path(state["root"]) / (str(uuid.uuid4()) + ".json")
    run(["open", "-n", "-g", "-W", state["app"], "--args", operation, output, text], timeout=40)
    result = json.loads(output.read_text())
    output.unlink()
    if isinstance(result, dict) and "error" in result:
        raise RuntimeError(result["error"])
    return result


def wait_for(state, filename, present=True):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        records = client(state, "search", filename)
        if bool(records) == present:
            return records
        time.sleep(0.2)
    raise AssertionError(f"{filename}: expected present={present}, records={records}")


def prepare(identity):
    if STATE.exists():
        raise RuntimeError("A signed fixture is already prepared; finish or clean it up first")
    token = uuid.uuid4().hex[:12]
    root = Path(tempfile.mkdtemp(prefix="everythingmac-scope-smoke-"))
    source = root / "source"
    source.mkdir()
    for folder in ["Shared", "ServiceSources"]:
        shutil.copytree(REPO / "App" / folder, source / folder)
    (source / "Sources").mkdir()
    for filename in ["IndexActor.swift", "IndexAccess.swift", "SearchClient.swift", "ServiceReplyWaiter.swift", "FolderSelection.swift"]:
        shutil.copy2(REPO / "App/Sources" / filename, source / "Sources" / filename)
    shutil.copy2(REPO / "scripts/scope-service-smoke/Main.swift", source / "Main.swift")
    app_id = f"com.everythingmac.scope-smoke.{token}"
    index_service = app_id + ".indexer"
    search_service = app_id + ".search"
    support_name = f"EverythingMacScopeSmoke-{token}"
    replacements = {
        "com.everythingmac.app": app_id,
        "com.everythingmac.indexer": index_service,
        "com.everythingmac.search": search_service,
        '"EverythingMacSearchService"': '"' + app_id + '.forwarder"',
        '"EverythingMac", isDirectory: true': f'"{support_name}", isDirectory: true',
        '"Everything-Mac", isDirectory: true': f'"{support_name}-legacy", isDirectory: true',
        "com.everythingmac.indexing-agent": app_id + ".index-agent",
        "com.everythingmac.indexing-service": app_id + ".retired-indexer",
    }
    for path in source.rglob("*.swift"):
        text = path.read_text()
        for before, after in replacements.items():
            text = text.replace(before, after)
        path.write_text(text)
    # Separate targets use the production source files and untouched trust checks.
    project = f"""name: ScopeSmoke
options:
  deploymentTarget:
    macOS: '14.0'
packages:
  IndexCore:
    path: {json.dumps(str(REPO))}
settings:
  base:
    SWIFT_VERSION: '6.0'
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: {json.dumps(identity)}
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
    ENABLE_HARDENED_RUNTIME: YES
targets:
  ScopeSmoke:
    type: application
    platform: macOS
    sources: [Shared, Main.swift, Sources/SearchClient.swift, Sources/ServiceReplyWaiter.swift, Sources/FolderSelection.swift]
    dependencies:
      - package: IndexCore
      - target: SmokeIndexer
      - target: SmokeSearch
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {app_id}
        GENERATE_INFOPLIST_FILE: YES
  SmokeIndexer:
    type: tool
    platform: macOS
    sources: [Shared, ServiceSources/Indexing, Sources/IndexActor.swift, Sources/IndexAccess.swift]
    dependencies:
      - package: IndexCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {app_id}
        PRODUCT_NAME: EverythingMacIndexingService
  SmokeSearch:
    type: tool
    platform: macOS
    sources: [Shared, ServiceSources/Search]
    dependencies:
      - package: IndexCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {app_id}.forwarder
        PRODUCT_NAME: {app_id}.forwarder
"""
    (source / "project.yml").write_text(project)
    log = root / "build.log"
    with log.open("w") as output:
        run(["xcodegen", "generate", "--spec", source / "project.yml", "--project", source], stdout=output, stderr=subprocess.STDOUT)
        run(["xcodebuild", "-project", source / "ScopeSmoke.xcodeproj", "-scheme", "ScopeSmoke", "-configuration", "Release",
             "-derivedDataPath", root / "build", "build"], stdout=output, stderr=subprocess.STDOUT)
    products = root / "build/Build/Products/Release"
    app = products / "ScopeSmoke.app"
    binaries = app / "Contents/MacOS"
    shutil.copy2(products / "EverythingMacIndexingService", binaries)
    shutil.copy2(products / (app_id + ".forwarder"), binaries / "EverythingMacSearchService")
    for filename, identifier in [("EverythingMacIndexingService", app_id), ("EverythingMacSearchService", app_id + ".forwarder")]:
        run(["codesign", "--force", "--options", "runtime", "--timestamp", "--identifier", identifier, "--sign", identity, binaries / filename])
    run(["codesign", "--force", "--options", "runtime", "--timestamp", "--identifier", app_id, "--sign", identity, app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    watched = Path.home() / "Documents" / support_name
    watched.mkdir(mode=0o700)
    (watched / "nested").mkdir()
    (watched / "nested/initial.txt").write_text("initial")
    support = Path.home() / "Library/Application Support" / support_name
    labels = []
    plists = []
    for label, executable, service in [(app_id + ".index-agent", "EverythingMacIndexingService", index_service),
                                        (app_id + ".search-agent", "EverythingMacSearchService", search_service)]:
        plist = root / (label + ".plist")
        plist.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": [str(binaries / executable)],
                                         "MachServices": {service: True}, "RunAtLoad": True,
                                         "ProcessType": "Background", "KeepAlive": True,
                                         "StandardOutPath": str(root / (executable + ".stdout")),
                                         "StandardErrorPath": str(root / (executable + ".stderr"))}))
        labels.append(label)
        plists.append(str(plist))
        run(["launchctl", "bootstrap", f"gui/{os.getuid()}", plist])
    state = {"root": str(root), "app": str(app), "watched": str(watched), "support": str(support),
             "labels": labels, "plists": plists, "bundleID": app_id}
    STATE.write_text(json.dumps(state))
    status = client(state, "status")
    assert status["coverage"]["scope"] == {"mode": "selectedFolders", "folders": []}, status
    print(json.dumps(state, indent=2), flush=True)
    subprocess.Popen(["open", "-n", str(app), "--args", "select", str(root / "selection.json")])
    print(f"Select this folder in the native picker: {watched}", flush=True)


def replace_root(state):
    watched = Path(state["watched"])
    previous = watched.with_name(watched.name + "-previous")
    watched.rename(previous)
    watched.mkdir(mode=0o700)
    (watched / "nested").mkdir()
    (watched / "nested/initial.txt").write_text("replacement initial")
    (watched / "replacement.txt").write_text("replacement")
    state["previous"] = str(previous)
    STATE.write_text(json.dumps(state))
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        status = client(state, "status")
        if status["totalCount"] == 0 and status["coverage"]["issues"]:
            break
        time.sleep(0.2)
    else:
        raise AssertionError("Replacing a root must suppress its former snapshot")
    wait_for(state, "replacement.txt", False)
    subprocess.Popen(["open", "-n", state["app"], "--args", "select", str(Path(state["root"]) / "selection.json")])
    print(f"PASS: replacement root stayed unavailable; reselect only {watched}", flush=True)


def verify(state):
    selection = json.loads((Path(state["root"]) / "selection.json").read_text())
    assert state["watched"] in selection["folders"], selection
    watched = Path(state["watched"])
    status = client(state, "status")
    assert status["coverage"]["monitoring"] == "live", status
    wait_for(state, "initial.txt")
    if "previous" in state:
        wait_for(state, "replacement.txt")
    # These paths are outside Desktop/Documents/Downloads shallow sweep targets.
    created = watched / "nested/live-create.txt"
    created.write_text("one")
    wait_for(state, created.name)
    created.write_text("modified data")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        records = client(state, "search", created.name)
        if records and records[0]["size"] == len("modified data"):
            break
    else:
        raise AssertionError("Live metadata update did not arrive")
    renamed = created.with_name("live-renamed.txt")
    created.rename(renamed)
    wait_for(state, renamed.name)
    wait_for(state, created.name, False)
    renamed.unlink()
    wait_for(state, renamed.name, False)
    # Scope application flushed the initial checkpoint; replay changes made afterward.
    index_job = f"gui/{os.getuid()}/{state['labels'][0]}"
    run(["launchctl", "bootout", index_job])
    (watched / "nested").rename(watched / "renamed-nested")
    (watched / "renamed-nested/offline.txt").write_text("offline")
    time.sleep(1)
    run(["launchctl", "bootstrap", f"gui/{os.getuid()}", state["plists"][0]])
    records = wait_for(state, "offline.txt")
    assert records[0]["path"].endswith("/renamed-nested/offline.txt"), records
    assert wait_for(state, "initial.txt")[0]["path"].endswith("/renamed-nested/initial.txt")
    for filename, mode in [("scope.json", 0o600), ("index.idx", 0o600)]:
        assert (Path(state["support"]) / filename).stat().st_mode & 0o777 == mode
    assert Path(state["support"]).stat().st_mode & 0o777 == 0o700
    client(state, "clear")
    wait_for(state, "offline.txt", False)
    run(["launchctl", "kickstart", "-k", index_job])
    wait_for(state, "initial.txt", False)
    print("PASS: signed picker → forwarding service → indexer; nested FSEvents CRUD, UI closed, durable restart/replay, scope removal, private storage", flush=True)


def cleanup(state):
    for label in state["labels"]:
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], check=False)
    shutil.rmtree(state["watched"], ignore_errors=True)
    if "previous" in state:
        shutil.rmtree(state["previous"], ignore_errors=True)
    shutil.rmtree(state["support"], ignore_errors=True)
    # Keep build logs/evidence; removal observers exit after their parent exits.
    STATE.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "replace", "verify", "cleanup"])
    parser.add_argument("--identity", default="Developer ID Application: Michael Garofalo (649367BDD4)")
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.identity)
    elif args.action == "replace":
        replace_root(json.loads(STATE.read_text()))
    elif args.action == "verify":
        verify(json.loads(STATE.read_text()))
    else:
        cleanup(json.loads(STATE.read_text()))
