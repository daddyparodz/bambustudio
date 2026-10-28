#!/usr/bin/env bash
set -euo pipefail

MANIFEST=""
RESULT_JSON=""
OWNER="${PPA_OWNER:-daddyparodz}"
ARCHIVE="${PPA_ARCHIVE:-bambustudio}"
SOURCE_DEADLINE="${PPA_SOURCE_ACCEPT_DEADLINE_SECONDS:-1800}"
BUILD_DEADLINE="${PPA_BUILD_DEADLINE_SECONDS:-7200}"

usage() {
  cat >&2 <<'USAGE'
Usage: verify-ppa-release.sh --manifest FILE --result-json FILE

Checks one pending PPA release once. It never waits for Launchpad. The result
JSON contains status=success, pending, retryable, or failed. If no expected
source reaches Launchpad before the source deadline, the result is retryable.
Partial publication and terminal/stalled build failures remain failed.
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --result-json) RESULT_JSON="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 2; }
[[ -n "$RESULT_JSON" ]] || usage
[[ "$SOURCE_DEADLINE" =~ ^[0-9]+$ ]] || { echo "Invalid source deadline: $SOURCE_DEADLINE" >&2; exit 2; }
[[ "$BUILD_DEADLINE" =~ ^[0-9]+$ ]] || { echo "Invalid build deadline: $BUILD_DEADLINE" >&2; exit 2; }
(( BUILD_DEADLINE >= SOURCE_DEADLINE )) || { echo "Build deadline must be >= source deadline" >&2; exit 2; }

export VERIFY_PPA_MANIFEST="$MANIFEST"
export VERIFY_PPA_RESULT="$RESULT_JSON"
export VERIFY_PPA_OWNER="$OWNER"
export VERIFY_PPA_ARCHIVE="$ARCHIVE"
export VERIFY_PPA_SOURCE_DEADLINE="$SOURCE_DEADLINE"
export VERIFY_PPA_BUILD_DEADLINE="$BUILD_DEADLINE"

python3 -u - <<'PY'
import datetime as dt
import json
import os
import pathlib

from launchpadlib.launchpad import Launchpad

manifest_path = pathlib.Path(os.environ["VERIFY_PPA_MANIFEST"])
result_path = pathlib.Path(os.environ["VERIFY_PPA_RESULT"])
owner = os.environ["VERIFY_PPA_OWNER"]
archive_name = os.environ["VERIFY_PPA_ARCHIVE"]
source_deadline = int(os.environ["VERIFY_PPA_SOURCE_DEADLINE"])
build_deadline = int(os.environ["VERIFY_PPA_BUILD_DEADLINE"])

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
required = ("channel", "package", "tag", "commit", "revision", "created_at", "sources")
missing = [key for key in required if key not in manifest]
if missing:
    raise SystemExit(f"Pending manifest missing fields: {missing}")
if manifest.get("status") != "pending":
    raise SystemExit(f"Expected pending manifest, got status={manifest.get('status')!r}")
if not isinstance(manifest["sources"], list) or not manifest["sources"]:
    raise SystemExit("Pending manifest has no sources")

try:
    created_at = dt.datetime.fromisoformat(str(manifest["created_at"]).replace("Z", "+00:00"))
except ValueError as exc:
    raise SystemExit(f"Invalid created_at in pending manifest: {exc}")
if created_at.tzinfo is None:
    created_at = created_at.replace(tzinfo=dt.timezone.utc)
now = dt.datetime.now(dt.timezone.utc)
age_seconds = max(0, int((now - created_at).total_seconds()))

base_result = {
    "schema": 1,
    "channel": manifest["channel"],
    "package": manifest["package"],
    "tag": manifest["tag"],
    "commit": manifest["commit"],
    "revision": int(manifest["revision"]),
    "created_at": manifest["created_at"],
    "checked_at": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}


def finish(status, message, source_states):
    result = dict(base_result)
    result.update({"status": status, "message": message, "sources": source_states})
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{status.upper()}: {message}", flush=True)
    for item in source_states:
        print(
            f"  {item.get('series')} {item.get('version')}: "
            f"source={item.get('source_status')} builds={item.get('build_states')}",
            flush=True,
        )
    raise SystemExit(0)

try:
    lp = Launchpad.login_anonymously(
        "bambustudio-ppa-release-verifier",
        "production",
        version="devel",
    )
    ppa = lp.people[owner].getPPAByName(name=archive_name)
    ubuntu = lp.distributions["ubuntu"]
except Exception as exc:
    finish("pending", f"Launchpad is temporarily unavailable: {exc}", [])

source_states = []
any_pending = False
source_query_error = False
failure_message = None
missing_after_deadline = []
failure_states = {
    "Failed to build",
    "Chroot problem",
    "Failed to upload",
    "Cancelled build",
    "Build for superseded Source",
}

for expected in manifest["sources"]:
    series = str(expected.get("series", ""))
    version = str(expected.get("version", ""))
    if not series or not version:
        raise SystemExit(f"Invalid source entry in pending manifest: {expected}")

    entry = {
        "series": series,
        "version": version,
        "source_status": "not-visible",
        "build_states": [],
    }

    try:
        distro_series = ubuntu.getSeries(name_or_version=series)
        publication = None
        for status in ("Pending", "Published"):
            pubs = ppa.getPublishedSources(
                source_name=manifest["package"],
                exact_match=True,
                distro_series=distro_series,
                status=status,
                order_by_date=True,
            )
            for pub in pubs:
                if str(pub.source_package_version) == version:
                    publication = pub
                    entry["source_status"] = str(pub.status)
                    break
            if publication is not None:
                break
    except Exception as exc:
        entry["source_status"] = f"query-error: {exc}"
        source_query_error = True
        any_pending = True
        source_states.append(entry)
        continue

    if publication is None:
        if age_seconds >= source_deadline:
            missing_after_deadline.append((series, version))
        else:
            any_pending = True
        source_states.append(entry)
        continue

    try:
        builds = list(publication.getBuilds())
    except Exception as exc:
        entry["build_states"] = [f"query-error: {exc}"]
        any_pending = True
        source_states.append(entry)
        continue

    states = sorted(str(build.buildstate) for build in builds)
    entry["build_states"] = states
    failed = [state for state in states if state in failure_states]
    if failed:
        failure_message = f"Launchpad build failure for {manifest['package']} {series} {version}: {failed}"
    elif not states or not all(state == "Successfully built" for state in states):
        # These are active post-build stages, not terminal build failures.
        # Keep the release pending even after the generic build deadline.
        postbuild_states = {"Uploading build", "Gathering build output"}
        if age_seconds >= build_deadline and not any(
            state in postbuild_states for state in states
        ):
            failure_message = (
                f"Launchpad builds did not complete for {manifest['package']} {series} {version} "
                f"within {build_deadline}s; states={states or ['not visible yet']}"
            )
        else:
            any_pending = True
    elif entry["source_status"] != "Published":
        # Successful builds alone do not prove that the source is published.
        any_pending = True
    source_states.append(entry)

if failure_message:
    finish("failed", failure_message, source_states)

if missing_after_deadline and source_query_error:
    finish(
        "pending",
        "Launchpad source query errors prevent a reliable absent-vs-partial publication decision",
        source_states,
    )

if missing_after_deadline:
    all_absent = (
        len(missing_after_deadline) == len(manifest["sources"])
        and all(item.get("source_status") == "not-visible" for item in source_states)
    )
    if all_absent:
        finish(
            "retryable",
            f"No expected Launchpad source became visible within {source_deadline}s; upload may be retried safely",
            source_states,
        )
    finish(
        "failed",
        f"Only part of the expected Launchpad source set became visible within {source_deadline}s: {missing_after_deadline}",
        source_states,
    )

if any_pending:
    finish("pending", "Launchpad publication/builds are still in progress", source_states)
finish("success", "All expected Launchpad source publications and builds succeeded", source_states)
PY
