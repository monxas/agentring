#!/usr/bin/env python3
"""Sign a CI-built iPhone app locally and install it without downloading LiveKit SDKs."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import plistlib
import re
import shutil
import secrets
import subprocess
import time
from pathlib import Path


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, capture_output=capture).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?", help="Unsigned AgentRing.app from the iPhone CI artifact")
    parser.add_argument("--device", required=True, help="Physical iPhone UDID")
    parser.add_argument("--team", required=True, help="Apple Developer team ID")
    parser.add_argument("--bundle-id", required=True, help="A bundle ID owned by your team")
    parser.add_argument("--profile", type=Path, help="Use an existing development profile instead of asking Xcode to provision")
    parser.add_argument("--key", type=Path, help="Import the private key matching a single-certificate manual profile into the login Keychain")
    parser.add_argument("--identity", help="SHA-1 of an existing local development signing identity")
    parser.add_argument("--provision-only", action="store_true", help="Prepare Apple signing without installing an app")
    args = parser.parse_args()
    source = args.app.resolve() if args.app else None
    if not args.provision_only and (source is None or not (source / "Info.plist").is_file()):
        parser.error("app must point to an extracted .app directory")
    root = Path(__file__).resolve().parent.parent
    work = root / ".build" / "ios-device-signing"
    work.mkdir(parents=True, exist_ok=True)
    project = work / "AgentRing.xcodeproj"
    project.mkdir(exist_ok=True)
    schemes = project / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "app-ios/AgentRing.xcodeproj/xcshareddata/xcschemes/AgentRing.xcscheme", schemes / "AgentRing.xcscheme")
    # Provision a tiny app with the same bundle ID/capabilities. This lets Xcode
    # manage Apple certificates and profiles without rebuilding the media SDKs.
    pbx = json.loads(run("plutil", "-convert", "json", "-o", "-", root / "app-ios/AgentRing.xcodeproj/project.pbxproj", capture=True))
    objects = pbx["objects"]
    for obj in objects.values():
        if obj["isa"] == "PBXProject":
            obj["packageReferences"] = []
        elif obj["isa"] == "PBXNativeTarget":
            obj["packageProductDependencies"] = []
        elif obj["isa"] == "PBXFrameworksBuildPhase":
            obj["files"] = []
        elif obj["isa"] == "PBXResourcesBuildPhase":
            obj["files"] = []
        elif obj["isa"] == "PBXSourcesBuildPhase":
            obj["files"] = ["F00000000000000000000002"]
        elif obj["isa"] == "XCBuildConfiguration":
            settings = obj["buildSettings"]
            settings.pop("ASSETCATALOG_COMPILER_APPICON_NAME", None)
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = args.bundle_id
            settings["DEVELOPMENT_TEAM"] = args.team
    objects["F00000000000000000000001"] = {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift", "path": "SigningProbe.swift", "sourceTree": "SOURCE_ROOT"}
    objects["F00000000000000000000002"] = {"isa": "PBXBuildFile", "fileRef": "F00000000000000000000001"}
    with (project / "project.pbxproj").open("wb") as f:
        plistlib.dump(pbx, f)
    app_sources = work / "AgentRing"
    app_sources.mkdir(exist_ok=True)
    for name in ("Info.plist", "AgentRing.entitlements"):
        shutil.copy2(root / "app-ios/AgentRing" / name, app_sources / name)
    (work / "SigningProbe.swift").write_text("import UIKit\n@main final class AppDelegate: UIResponder, UIApplicationDelegate { var window: UIWindow? }\n")
    derived = work / "DerivedData"
    if args.profile:
        profile = args.profile.resolve()
        probe = None
    else:
        run("xcodebuild", "-project", project, "-scheme", "AgentRing", "-configuration", "Debug",
            "-destination", f"id={args.device}", "-derivedDataPath", derived,
            "-sdk", "iphoneos", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            f"DEVELOPMENT_TEAM={args.team}", f"PRODUCT_BUNDLE_IDENTIFIER={args.bundle_id}")
        probe = derived / "Build" / "Products" / "Debug-iphoneos" / "AgentRing.app"
        profile = probe / "embedded.mobileprovision"
    if not profile.is_file():
        raise RuntimeError("Xcode did not produce an iPhone provisioning profile")
    metadata = plistlib.loads(run("security", "cms", "-D", "-i", profile, capture=True))
    if args.team not in metadata.get("TeamIdentifier", []):
        raise RuntimeError("The profile belongs to a different Apple Developer team")
    application_id = metadata.get("Entitlements", {}).get("application-identifier", "")
    if not application_id.endswith("." + args.bundle_id):
        raise RuntimeError("The profile does not match the requested app bundle identifier")
    if metadata.get("ExpirationDate", datetime.min).replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise RuntimeError("The development provisioning profile has expired")
    if metadata.get("Entitlements", {}).get("aps-environment") != "development":
        raise RuntimeError("This app needs a development profile with Push Notifications enabled")
    if args.device not in metadata.get("ProvisionedDevices", []):
        raise RuntimeError("The generated profile does not include this iPhone; register it with your team in Xcode")
    if args.key:
        if len(metadata["DeveloperCertificates"]) != 1:
            raise RuntimeError("Private-key import requires a profile containing exactly one certificate")
        cert_der = work / "Development.cer"
        cert_pem = work / "Development.pem"
        identity_file = work / "Development.p12"
        cert_der.write_bytes(metadata["DeveloperCertificates"][0])
        run("/usr/bin/openssl", "x509", "-inform", "DER", "-in", cert_der, "-out", cert_pem)
        password = secrets.token_urlsafe(32)
        subprocess.run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(args.key.resolve()), "-in", str(cert_pem),
                        "-out", str(identity_file), "-passout", "stdin"], input=(password + "\n").encode(), check=True)
        keychain = run("security", "default-keychain", "-d", "user", capture=True).decode().strip().strip('"')
        try:
            imported = subprocess.run(["security", "import", str(identity_file), "-k", keychain, "-P", password,
                                       "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
            if imported.returncode:
                raise RuntimeError("Could not import the development identity into the login Keychain")
        finally:
            identity_file.unlink(missing_ok=True)
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in metadata["DeveloperCertificates"]}
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).decode()
    identity = args.identity or next((value for value in re.findall(r"\b[0-9A-F]{40}\b", identities) if value in allowed), None)
    if identity not in allowed:
        raise RuntimeError("No local signing identity matches the generated Apple profile")
    if args.provision_only:
        print("Apple signing is ready for this iPhone")
        return
    destination = work / "AgentRing.app"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    info_path = destination / "Info.plist"
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    info["CFBundleIdentifier"] = args.bundle_id
    info["APNSEnvironment"] = "sandbox"
    with info_path.open("wb") as f:
        plistlib.dump(info, f)
    shutil.copy2(profile, destination / "embedded.mobileprovision")
    if probe:
        entitlements = run("codesign", "-d", "--entitlements", ":-", probe, capture=True)
    else:
        values = metadata["Entitlements"].copy()
        values["application-identifier"] = metadata["ApplicationIdentifierPrefix"][0] + "." + args.bundle_id
        values["keychain-access-groups"] = [values["application-identifier"]]
        entitlements = plistlib.dumps(values)
    entitlement_path = work / "Entitlements.plist"
    # Validate the plist before passing it back to codesign.
    plistlib.loads(entitlements)
    entitlement_path.write_bytes(entitlements)
    for library in sorted(destination.rglob("*.dylib"), key=lambda p: len(p.parts), reverse=True):
        run("codesign", "--force", "--sign", identity, "--timestamp=none", library)
        run("codesign", "--verify", "--strict", library)
    frameworks = sorted(destination.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True)
    for framework in frameworks:
        run("codesign", "--force", "--sign", identity, "--timestamp=none", framework)
    run("codesign", "--force", "--sign", identity, "--entitlements", entitlement_path, "--timestamp=none", destination)
    run("codesign", "--verify", "--deep", "--strict", destination)
    run("xcrun", "devicectl", "device", "install", "app", "--device", args.device, destination)
    installed = {
        "bundle_id": args.bundle_id, "device": args.device,
        "build": info.get("CFBundleVersion"), "version": info.get("CFBundleShortVersionString"),
        "installed_at": datetime.now(timezone.utc).isoformat(), "signature_verified": True,
        "source_executable_sha256": hashlib.sha256((source / info["CFBundleExecutable"]).read_bytes()).hexdigest(),
        "launched": False,
    }
    evidence = work / "Installation.json"
    evidence.write_text(json.dumps(installed, indent=2) + "\n")
    launch = subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                             args.bundle_id], capture_output=True, text=True)
    if launch.returncode:
        if "Locked" in launch.stderr or "could not be, unlocked" in launch.stderr:
            print("Installed and signature verified. Unlock the physical iPhone, then launch the app to finish validation.")
            raise SystemExit(2)
        raise RuntimeError("App installed, but launch failed: " + launch.stderr.strip())
    installed["launched"] = True
    evidence.write_text(json.dumps(installed, indent=2) + "\n")
    time.sleep(3)
    processes_path = work / "RunningProcesses.json"
    run("xcrun", "devicectl", "device", "info", "processes", "--device", args.device,
        "--search", "AgentRing.app/AgentRing", "--json-output", processes_path)
    processes = json.loads(processes_path.read_text()).get("result", {}).get("runningProcesses", [])
    if not any("AgentRing.app/AgentRing" in str(p.get("executable", "")) for p in processes):
        raise RuntimeError("The app installed but exited during startup; inspect it with devicectl process launch --console")
    print(f"Installed, launched and verified running: {args.bundle_id} on {args.device}")


if __name__ == "__main__":
    main()
