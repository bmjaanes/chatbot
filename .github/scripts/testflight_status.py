"""Prints the processing and TestFlight status of the newest builds, using the App Store Connect API.

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 from the environment. Never prints the key.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import jwt  # PyJWT

BUNDLE_ID = "com.bmjaanes.nexttime"
API = "https://api.appstoreconnect.apple.com/v1"

EXPLAIN = {
    "PROCESSING": "Apple is still processing this build. Check again in a few minutes.",
    "FAILED": "Apple couldn't process this build. Check the email address on the Apple developer account for details.",
    "INVALID": "Apple rejected this build. Check the email address on the Apple developer account for the reason.",
    "VALID": "Processed and ready.",
    "READY_FOR_BETA_TESTING": "Ready. Add yourself under TestFlight → Internal Testing to install it.",
    "IN_BETA_TESTING": "Available to your internal testers in the TestFlight app.",
    "MISSING_EXPORT_COMPLIANCE": "Waiting on the encryption question: open the build in App Store Connect and answer it.",
    "PROCESSING_EXCEPTION": "Apple hit a problem while preparing it for TestFlight. Try uploading again.",
    "EXPIRED": "Expired (TestFlight builds last 90 days). Upload a new one.",
}


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def get(path, params):
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"::error::App Store Connect answered {e.code}: {e.read().decode()[:500]}")
        sys.exit(1)


apps = get("apps", {"filter[bundleId]": BUNDLE_ID})["data"]
if not apps:
    print(f"::error::No app with bundle ID {BUNDLE_ID} in App Store Connect. Create it under Apps → + → New App.")
    sys.exit(1)
app = apps[0]
print(f"App: {app['attributes']['name']} ({BUNDLE_ID})\n")

builds = get("builds", {
    "filter[app]": app["id"],
    "sort": "-uploadedDate",
    "limit": 5,
    "include": "buildBetaDetail",
    "fields[builds]": "version,processingState,uploadedDate,expired,buildBetaDetail",
    "fields[buildBetaDetails]": "internalBuildState",
})
details = {d["id"]: d["attributes"] for d in builds.get("included", []) if d["type"] == "buildBetaDetails"}
if not builds["data"]:
    print("No builds yet. Apple can take a few minutes after an upload before a build appears; if it never does, "
          "it was rejected during processing and Apple emailed the account holder.")
    sys.exit(0)

lines = []
for b in builds["data"]:
    a = b["attributes"]
    rel = (b.get("relationships", {}).get("buildBetaDetail") or {}).get("data") or {}
    beta = details.get(rel.get("id"), {}).get("internalBuildState")
    state = "EXPIRED" if a.get("expired") else (beta if a["processingState"] == "VALID" and beta else a["processingState"])
    line = f"Build 1.0 ({a['version']}) uploaded {a['uploadedDate'][:16].replace('T', ' ')} UTC: {state}\n    {EXPLAIN.get(state, '')}"
    print(line)
    lines.append(line)

summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as f:
        f.write("### TestFlight builds\n\n```\n" + "\n".join(lines) + "\n```\n")
