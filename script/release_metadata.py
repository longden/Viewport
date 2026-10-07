#!/usr/bin/env python3
"""Validate release inputs and generate bundle metadata (no signing secrets)."""
import os
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


def validate_version(root, env):
    version = env["VIEWPORT_VERSION"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Release version must have three numeric components")
    if not re.fullmatch(r"[1-9][0-9]*", env["VIEWPORT_BUILD"]):
        raise ValueError("Build number must be a positive integer")
    header = re.search(r"^// Viewport version: ([0-9]+(?:\.[0-9]+)*)", (root / "Package.swift").read_text(), re.M)
    if header is None or header[1] != version:
        raise ValueError("VIEWPORT_VERSION must match the Package.swift version header")


def bundle_metadata(env):
    enabled = env.get("VIEWPORT_UPDATES_ENABLED", "0") == "1"
    data = {
        "CFBundleExecutable": "Viewport", "CFBundleIdentifier": "com.longden.viewport",
        "CFBundleName": "Viewport", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": env["VIEWPORT_VERSION"],
        "CFBundleVersion": env["VIEWPORT_BUILD"],
        "CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon",
        "LSMinimumSystemVersion": "26.0", "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSCameraUsageDescription": "Viewport uses video access to display the screen of an iPhone or iPad connected over USB.",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "ViewportUpdatesEnabled": enabled,
    }
    if enabled:
        feed = env["VIEWPORT_FEED_URL"]
        parsed = urlparse(feed)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("The update feed must be an HTTPS URL without credentials")
        data.update({
            "SUFeedURL": feed,
            "ViewportAppleSigningUpdates": True,
            "SUVerifyUpdateBeforeExtraction": False,
            "SURequireSignedFeed": False,
            "SUAutomaticallyUpdate": False,
            "SUAllowsAutomaticUpdates": False,
            "SUScheduledCheckInterval": 86400,
        })
        # Omit SUEnableAutomaticChecks so Sparkle can ask for consent after setup.
    return data


def main():
    if len(sys.argv) != 3:
        raise ValueError("Usage: release_metadata.py validate-version <root> | write-plist <Info.plist>")
    command, path = sys.argv[1:]
    if command == "validate-version":
        validate_version(Path(path), os.environ)
    elif command == "write-plist":
        with open(path, "wb") as output:
            plistlib.dump(bundle_metadata(os.environ), output)
    else:
        raise ValueError("Unknown command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
