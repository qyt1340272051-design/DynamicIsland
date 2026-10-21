#!/usr/bin/env python3
"""Verify three already-downloaded public v0.6.0-beta.2 assets; never run App."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

TAG = "v0.6.0-beta.2"
PRODUCT = "Dynamic Island"
BUNDLE_ID = "com.rong5.dynamic-island-mac"
DMG = "Dynamic-Island-0.6.0-beta.2-local.dmg"
CHECKSUM = DMG + ".sha256"
MANIFEST = "Dynamic-Island-0.6.0-beta.2-local.json"
EXPECTED_ASSETS = {DMG, CHECKSUM, MANIFEST}
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def unique_json_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Manifest contains a duplicate field: " + key)
        result[key] = value
    return result


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets_directory", type=Path)
    parser.add_argument("result_json", type=Path)
    args = parser.parse_args()
    result_path = args.result_json.resolve()
    # All writes belong to this acceptance task's /tmp work, never the repo.
    require(result_path.is_relative_to(Path("/tmp").resolve()), "Result JSON must be under /tmp")
    report = {
        "tag": TAG,
        "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ok": False,
        "scope": "Already-downloaded public assets and read-only mounted App verification; no App launch",
        "commands": [],
        "checks": {},
        "cleanup": {"mountCreated": False, "normalDetach": None, "temporaryDirectoryRemoved": False},
    }
    temporary_root = None
    mountpoint = None
    attach_attempted = False
    mounted = False
    error = None

    def run(command, timeout=90, check=True, keep_stdout=True):
        try:
            completed = subprocess.run(command, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            report["commands"].append({"command": command, "timeoutSeconds": timeout, "timedOut": True})
            raise VerificationError("Command timed out: " + command[0]) from exc
        entry = {"command": command, "exitCode": completed.returncode}
        if keep_stdout:
            entry["stdoutTail"] = completed.stdout.decode("utf-8", errors="replace")[-5000:]
        entry["stderrTail"] = completed.stderr.decode("utf-8", errors="replace")[-5000:]
        report["commands"].append(entry)
        if check:
            require(completed.returncode == 0, "Command failed: " + " ".join(command))
        return completed

    try:
        assets = args.assets_directory.resolve(strict=True)
        require(assets.is_dir(), "Assets argument is not a directory")
        require(result_path.parent != assets, "Result JSON must be outside the exact three-asset directory")
        require(set(item.name for item in assets.iterdir()) == EXPECTED_ASSETS,
                "Directory must contain exactly the three expected Release asset names")
        for name in EXPECTED_ASSETS:
            require((assets / name).is_file() and not (assets / name).is_symlink(),
                    "Each asset must be a regular non-symlink file: " + name)
        report["assetsDirectory"] = str(assets)
        report["assets"] = {name: {"bytes": (assets / name).stat().st_size, "sha256": digest(assets / name)}
                            for name in sorted(EXPECTED_ASSETS)}
        report["checks"]["exactThreeAssetNames"] = True

        manifest = json.loads((assets / MANIFEST).read_text(), object_pairs_hook=unique_json_fields)
        require(isinstance(manifest, dict), "Manifest must be an object")
        require(set(manifest) == {"product", "tag", "bundleIdentifier", "marketingVersion", "buildNumber",
                                  "architectures", "notarized", "artifact", "sha256"},
                "Manifest fields differ from the release script contract")
        for key, expected in {"product": PRODUCT, "tag": TAG, "bundleIdentifier": BUNDLE_ID,
                              "marketingVersion": "0.6.0", "buildNumber": "4", "artifact": DMG}.items():
            require(manifest.get(key) == expected, "Manifest mismatch: " + key)
        require(manifest.get("notarized") is False, "Manifest must explicitly state notarized=false")
        require(isinstance(manifest.get("architectures"), str), "Manifest architectures must be a string")
        manifest_architectures = manifest["architectures"].split()
        require(len(manifest_architectures) == 2 and set(manifest_architectures) == EXPECTED_ARCHITECTURES,
                "Manifest must list only arm64 and x86_64 exactly once")
        require(isinstance(manifest.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"]),
                "Manifest sha256 is malformed")
        checksum = (assets / CHECKSUM).read_text(encoding="ascii")
        require(re.fullmatch(r"[0-9a-f]{64}  " + re.escape(DMG) + r"\n?", checksum) is not None,
                "Checksum must contain exactly one canonical SHA-256 line for the DMG")
        actual_sha256 = report["assets"][DMG]["sha256"]
        require(checksum.split()[0] == actual_sha256 == manifest["sha256"],
                "Actual DMG bytes, checksum and manifest SHA-256 disagree")
        report["manifest"] = manifest
        report["checks"]["manifestAndChecksumMatchActualBytes"] = True

        run(["hdiutil", "verify", str(assets / DMG)], timeout=180)
        report["checks"]["diskImageIntegrity"] = True
        temporary_root = Path(tempfile.mkdtemp(prefix="dynamic-island-public-artifact-", dir="/tmp"))
        mountpoint = temporary_root / "mount"
        mountpoint.mkdir()
        report["cleanup"]["mountCreated"] = True
        report["cleanup"]["temporaryDirectory"] = str(temporary_root)
        # Mark attempted before invocation so finally also handles partial attach.
        attach_attempted = True
        attached = run(["hdiutil", "attach", str(assets / DMG), "-nobrowse", "-readonly",
                        "-mountpoint", str(mountpoint), "-plist"], timeout=90)
        attach_info = plistlib.loads(attached.stdout)
        require(isinstance(attach_info, dict), "Invalid hdiutil attach metadata")
        mounted = True
        report["mount"] = {"readonlyRequested": True, "nobrowse": True,
                           "devices": [{key: entity[key] for key in ("dev-entry", "mount-point", "content-hint") if key in entity}
                                       for entity in attach_info.get("system-entities", [])]}
        require(os.path.ismount(mountpoint), "The requested temporary path is not mounted")

        app = mountpoint / (PRODUCT + ".app")
        require(app.is_dir() and not app.is_symlink(), "DMG does not contain a regular App bundle")
        applications = mountpoint / "Applications"
        require(applications.is_symlink() and os.readlink(applications) == "/Applications",
                "DMG Applications link is missing or points elsewhere")
        report["checks"]["applicationsLink"] = "/Applications"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        for key, expected in {"CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "4",
                              "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": PRODUCT,
                              "LSMinimumSystemVersion": "26.0"}.items():
            require(info.get(key) == expected, "App Info.plist mismatch: " + key)
        require(info.get("LSUIElement") is True, "LSUIElement must be true")
        report["appInfo"] = {key: info[key] for key in ("CFBundleShortVersionString", "CFBundleVersion",
                                                       "CFBundleIdentifier", "CFBundleExecutable",
                                                       "LSMinimumSystemVersion", "LSUIElement")}
        executable = app / "Contents/MacOS" / PRODUCT
        require(executable.is_file() and not executable.is_symlink(), "App executable is missing or symlinked")
        architecture_result = run(["lipo", "-archs", str(executable)])
        architectures = architecture_result.stdout.decode("ascii").split()
        require(len(architectures) == 2 and set(architectures) == EXPECTED_ARCHITECTURES,
                "Actual executable must contain only arm64 and x86_64 exactly once")
        report["executable"] = {"architectures": architectures, "sha256": digest(executable),
                                "bytes": executable.stat().st_size}
        report["checks"]["versionBuildBundleMinimumOSAndUniversalExecutable"] = True

        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
        metadata_result = run(["codesign", "-d", "--verbose=4", str(app)])
        metadata = (metadata_result.stdout + metadata_result.stderr).decode("utf-8", errors="replace")
        require(re.search(r"^Signature=adhoc$", metadata, re.MULTILINE), "Expected ad hoc App signature")
        require(re.search(r"^.*flags=.*\bruntime\b.*$", metadata, re.MULTILINE),
                "Hardened Runtime signature flag is missing")
        report["signature"] = {"strictDeepVerificationPassed": True, "adHoc": True,
                               "hardenedRuntime": True, "metadata": metadata}
        entitlements_result = run(["codesign", "-d", "--entitlements", ":-", str(app)], keep_stdout=False)
        entitlements = plistlib.loads(entitlements_result.stdout)
        require(isinstance(entitlements, dict), "Invalid exported entitlements")
        require("com.apple.security.get-task-allow" not in entitlements or
                entitlements["com.apple.security.get-task-allow"] is False,
                "Distribution App must not permit get-task-allow")
        for key in ("com.apple.security.app-sandbox", "com.apple.security.cs.allow-jit",
                    "com.apple.security.network.client"):
            require(entitlements.get(key) is True, "Expected entitlement is not enabled: " + key)
        # Existing entitlements are booleans, strings and arrays/dictionaries only.
        json.dumps(entitlements)
        report["entitlements"] = entitlements
        report["checks"]["distributionSignatureAndEntitlements"] = True
    except Exception as exc:
        error = {"type": type(exc).__name__, "message": str(exc)}
    finally:
        if attach_attempted and mountpoint is not None and (mounted or os.path.ismount(mountpoint)):
            try:
                detached = run(["hdiutil", "detach", str(mountpoint)], timeout=90, check=False)
                report["cleanup"]["normalDetach"] = detached.returncode == 0 and not os.path.ismount(mountpoint)
                if not report["cleanup"]["normalDetach"]:
                    error = error or {"type": "CleanupError", "message": "Normal detach failed; temporary mount retained"}
            except Exception as exc:
                report["cleanup"]["normalDetach"] = False
                error = error or {"type": type(exc).__name__, "message": "Detach: " + str(exc)}
        if temporary_root is not None and mountpoint is not None and not os.path.ismount(mountpoint):
            try:
                shutil.rmtree(temporary_root)
                report["cleanup"]["temporaryDirectoryRemoved"] = True
            except Exception as exc:
                error = error or {"type": type(exc).__name__, "message": "Temporary cleanup: " + str(exc)}
        report["ok"] = error is None
        if error:
            report["error"] = error
        report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"ok": report["ok"], "tag": TAG, "result": str(result_path),
                          "error": error}, ensure_ascii=False))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
