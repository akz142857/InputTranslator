#!/usr/bin/env python3

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile


REPOSITORY = "https://github.com/akz142857/InputTranslator"
SIGNING_ACCOUNT = "InputTranslatorUpdates"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main():
    parser = argparse.ArgumentParser(description="Sign an InputTranslator release ZIP and create its appcast.xml.")
    parser.add_argument("sparkle_bin", type=Path, help="bin directory from the Sparkle distribution")
    parser.add_argument("archive", type=Path, help="final, notarized InputTranslator release ZIP")
    options = parser.parse_args()
    tools = options.sparkle_bin.resolve()
    archive = options.archive.resolve()

    match = re.fullmatch(r"InputTranslator-v(\d+\.\d+\.\d+)-macOS-universal\.zip", archive.name)
    if not match:
        parser.error("expected InputTranslator-v<version>-macOS-universal.zip")
    version = match[1]
    with ZipFile(archive) as release:
        info = plistlib.loads(release.read("InputTranslator.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "com.claycosmos.InputTranslator":
        parser.error("the ZIP must contain the release bundle ID com.claycosmos.InputTranslator")
    if info.get("CFBundleShortVersionString") != version:
        parser.error("the archive filename and app version differ")
    build = info.get("CFBundleVersion", "")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        parser.error("the app must have a positive integer CFBundleVersion")

    feed_url = f"{REPOSITORY}/releases/latest/download/appcast.xml"
    if info.get("SUFeedURL") != feed_url or info.get("SURequireSignedFeed") is not True:
        parser.error("the app must use the signed GitHub Releases feed")
    key = subprocess.check_output(
        [tools / "generate_keys", "--account", SIGNING_ACCOUNT, "-p"], text=True
    ).strip()
    if not key or key != info.get("SUPublicEDKey"):
        parser.error("the signing key in Keychain does not match the app's public key")

    download_prefix = f"{REPOSITORY}/releases/download/v{version}/"
    output = archive.with_name("appcast.xml")
    with tempfile.TemporaryDirectory(prefix=".inputtranslator-appcast-", dir=archive.parent) as directory:
        work = Path(directory)
        shutil.copyfile(archive, work / archive.name)
        feed = work / "appcast.xml"
        subprocess.run([
            tools / "generate_appcast", "--account", SIGNING_ACCOUNT, "--maximum-deltas", "0",
            "--download-url-prefix", download_prefix, "--link", f"{REPOSITORY}/releases/latest",
            "--full-release-notes-url", f"{REPOSITORY}/releases/tag/v{version}",
            "-o", feed, work,
        ], check=True)

        item = ET.parse(feed).find("./channel/item")
        if item is None or item.findtext(f"{{{SPARKLE_NAMESPACE}}}version") != build:
            parser.error("the generated update does not match the app's build number")
        enclosure = item.find("enclosure")
        if (enclosure is None or enclosure.get("url") != download_prefix + archive.name
                or enclosure.get("length") != str(archive.stat().st_size)):
            parser.error("the generated update does not match the release ZIP")
        signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
        if not signature:
            parser.error("the generated update is missing its archive signature")
        subprocess.run([tools / "sign_update", "--account", SIGNING_ACCOUNT, "--verify", feed], check=True)
        subprocess.run([tools / "sign_update", "--account", SIGNING_ACCOUNT, "--verify", archive, signature],
                       check=True)
        os.replace(feed, output)
    print(output)


if __name__ == "__main__":
    main()
