#!/usr/bin/env bash
set -euo pipefail

OWNER=""
ARCHIVE=""
APP_NAME="bambustudio-ppa-sync"
DRY_RUN="false"
KEEP_VERSIONS="3"
RESULT_JSON=""
declare -a PACKAGES=()
declare -a RESERVE_PACKAGES=()
declare -a RESERVE_SERIES=()

usage() {
  cat >&2 <<'USAGE'
Usage: prune-ppa.sh --owner <owner> --archive <archive> --package <name> [--package <name> ...] [--reserve-package <name> ...] [--reserve-series <series> ...] [--keep-versions <count>] [--result-json <path>] [--app-name <name>] [--dry-run]

Keeps at most the newest N Debian source versions for each package and Ubuntu
series. For packages named with --reserve-package, one retention slot is kept
free for the impending upload, so only N-1 existing active versions are kept.
When --reserve-series is supplied, that reservation applies only to those Ubuntu
series; otherwise it applies to every series for the reserved package.
Published and Superseded publications outside the retention window are
explicitly scheduled for deletion. Deleted publication history is considered
cleanup-pending while Launchpad exposes a scheduled deletion date for that
publication; terminal Deleted history without a deletion schedule does not
block later uploads.

Requires:
  - python3-launchpadlib installed
  - dpkg installed
  - Launchpad OAuth credentials available from one of:
    0) LAUNCHPAD_CREDENTIALS (raw credential text)
    1) LAUNCHPAD_CREDENTIALS_FILE
    2) LAUNCHPAD_OAUTH_CREDENTIALS_FILE

No implicit credential discovery is performed. For local use, set one of the
file variables above to the exact path of an existing credential file.
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --archive)
      ARCHIVE="${2:-}"
      shift 2
      ;;
    --package)
      PACKAGES+=("${2:-}")
      shift 2
      ;;
    --reserve-package)
      RESERVE_PACKAGES+=("${2:-}")
      shift 2
      ;;
    --reserve-series)
      RESERVE_SERIES+=("${2:-}")
      shift 2
      ;;
    --keep-versions)
      KEEP_VERSIONS="${2:-}"
      shift 2
      ;;
    --result-json)
      RESULT_JSON="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$OWNER" ]] || usage
[[ -n "$ARCHIVE" ]] || usage
(( ${#PACKAGES[@]} > 0 )) || usage
[[ "$KEEP_VERSIONS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --keep-versions value: $KEEP_VERSIONS" >&2; exit 2; }
command -v dpkg >/dev/null 2>&1 || { echo "dpkg is required" >&2; exit 2; }

for reserve_pkg in "${RESERVE_PACKAGES[@]}"; do
  found=false
  for pkg in "${PACKAGES[@]}"; do
    if [[ "$reserve_pkg" == "$pkg" ]]; then
      found=true
      break
    fi
  done
  [[ "$found" == "true" ]] || { echo "--reserve-package must also be listed with --package: $reserve_pkg" >&2; exit 2; }
done

for series in "${RESERVE_SERIES[@]}"; do
  [[ -n "$series" && "$series" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid --reserve-series value: $series" >&2; exit 2; }
done

resolve_credentials_file() {
  if [[ -n "${LAUNCHPAD_CREDENTIALS:-}" ]]; then
    local tmp_cred
    tmp_cred="$(mktemp)"
    chmod 600 "$tmp_cred"
    printf '%s\n' "$LAUNCHPAD_CREDENTIALS" > "$tmp_cred"
    export PRUNE_TEMP_CREDENTIALS_FILE="$tmp_cred"
    printf '%s\n' "$tmp_cred"
    return 0
  fi

  if [[ -n "${LAUNCHPAD_CREDENTIALS_FILE:-}" ]]; then
    printf '%s\n' "$LAUNCHPAD_CREDENTIALS_FILE"
    return 0
  fi
  if [[ -n "${LAUNCHPAD_OAUTH_CREDENTIALS_FILE:-}" ]]; then
    printf '%s\n' "$LAUNCHPAD_OAUTH_CREDENTIALS_FILE"
    return 0
  fi

  # Credentials must be supplied explicitly; never search local profiles.
  return 1
}

if credentials_file="$(resolve_credentials_file)"; then
  if [[ ! -f "$credentials_file" ]]; then
    echo "Credential file does not exist: $credentials_file" >&2
    exit 2
  fi
  export LAUNCHPAD_CREDENTIALS_FILE="$credentials_file"
else
  echo "No Launchpad OAuth credential file found; refusing to skip PPA retention." >&2
  exit 2
fi

cleanup() {
  if [[ -n "${PRUNE_TEMP_CREDENTIALS_FILE:-}" && -f "${PRUNE_TEMP_CREDENTIALS_FILE}" ]]; then
    rm -f "${PRUNE_TEMP_CREDENTIALS_FILE}"
  fi
}
trap cleanup EXIT

packages_csv=""
for pkg in "${PACKAGES[@]}"; do
  if [[ -z "$packages_csv" ]]; then
    packages_csv="$pkg"
  else
    packages_csv="$packages_csv,$pkg"
  fi
done

reserve_packages_csv=""
for pkg in "${RESERVE_PACKAGES[@]}"; do
  if [[ -z "$reserve_packages_csv" ]]; then
    reserve_packages_csv="$pkg"
  else
    reserve_packages_csv="$reserve_packages_csv,$pkg"
  fi
done

reserve_series_csv=""
for series in "${RESERVE_SERIES[@]}"; do
  if [[ -z "$reserve_series_csv" ]]; then
    reserve_series_csv="$series"
  else
    reserve_series_csv="$reserve_series_csv,$series"
  fi
done

export PRUNE_OWNER="$OWNER"
export PRUNE_ARCHIVE="$ARCHIVE"
export PRUNE_PACKAGES_CSV="$packages_csv"
export PRUNE_RESERVE_PACKAGES_CSV="$reserve_packages_csv"
export PRUNE_RESERVE_SERIES_CSV="$reserve_series_csv"
export PRUNE_APP_NAME="$APP_NAME"
export PRUNE_DRY_RUN="$DRY_RUN"
export PRUNE_KEEP_VERSIONS="$KEEP_VERSIONS"
export PRUNE_RESULT_JSON="$RESULT_JSON"

python3 <<'PY'
import functools
import json
import os
import pathlib
import subprocess
import sys
import time
from collections import defaultdict

from launchpadlib.launchpad import Launchpad
from lazr.restfulclient.errors import ServerError


def debian_version_compare(left, right):
    if left == right:
        return 0
    if subprocess.run(
        ["dpkg", "--compare-versions", left, "gt", right],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return 1
    if subprocess.run(
        ["dpkg", "--compare-versions", left, "lt", right],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return -1
    raise RuntimeError(f"Could not compare Debian versions: {left!r} and {right!r}")


def retry_launchpad_read(label, operation, attempts=4):
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except ServerError as exc:
            if attempt == attempts:
                raise
            delay = 2 ** (attempt - 1)
            print(
                f"Launchpad read failed for {label} (attempt {attempt}/{attempts}): "
                f"{exc}; retrying in {delay}s",
                file=sys.stderr,
            )
            time.sleep(delay)


def series_name(pub):
    series = retry_launchpad_read(
        "publication distro_series",
        lambda: getattr(pub, "distro_series", None),
    )
    if series is None:
        return "unknown"
    return str(
        retry_launchpad_read(
            "distro series name",
            lambda: getattr(series, "name", ""),
        )
        or retry_launchpad_read(
            "distro series self_link",
            lambda: getattr(series, "self_link", ""),
        )
        or "unknown"
    )


def publication_status(pub):
    return str(getattr(pub, "status", "") or "")


def scheduled_deletion(pub):
    return (
        getattr(pub, "scheduled_deletion_date", None)
        or getattr(pub, "scheduleddeletiondate", None)
    )


def get_published_sources(ppa, pkg, status):
    return retry_launchpad_read(
        f"{pkg} {status} source publications",
        lambda: list(
            ppa.getPublishedSources(
                source_name=pkg,
                exact_match=True,
                status=status,
                order_by_date=True,
            )
        ),
    )


owner = os.environ["PRUNE_OWNER"]
archive = os.environ["PRUNE_ARCHIVE"]
packages = [p for p in os.environ["PRUNE_PACKAGES_CSV"].split(",") if p]
reserve_packages = {p for p in os.environ.get("PRUNE_RESERVE_PACKAGES_CSV", "").split(",") if p}
reserve_series = {s for s in os.environ.get("PRUNE_RESERVE_SERIES_CSV", "").split(",") if s}
app_name = os.environ["PRUNE_APP_NAME"]
dry_run = os.environ["PRUNE_DRY_RUN"] == "true"
keep_versions = int(os.environ["PRUNE_KEEP_VERSIONS"])
result_json = os.environ.get("PRUNE_RESULT_JSON", "")
credentials_file = os.environ["LAUNCHPAD_CREDENTIALS_FILE"]

lp = Launchpad.login_with(
    app_name,
    "production",
    version="devel",
    credentials_file=credentials_file,
)
ppa = retry_launchpad_read(
    "PPA lookup",
    lambda: lp.people[owner].getPPAByName(name=archive),
)

status_priority = {"Published": 2, "Superseded": 1}
deleted = 0
already_scheduled = 0
pending_deleted = 0
terminal_deleted = 0
excess_publications = 0
retained = {}

for pkg in packages:
    active_publications = []
    for status in ("Published", "Superseded"):
        active_publications.extend(get_published_sources(ppa, pkg, status))

    deleted_publications = get_published_sources(ppa, pkg, "Deleted")
    seen_deleted = set()
    for pub in deleted_publications:
        key = str(getattr(pub, "self_link", "") or "") or (
            series_name(pub),
            str(getattr(pub, "source_package_version", "") or ""),
        )
        if key in seen_deleted:
            continue
        seen_deleted.add(key)
        scheduled = scheduled_deletion(pub)
        if not scheduled:
            terminal_deleted += 1
            continue
        pending_deleted += 1
        print(
            f"{pkg}/{series_name(pub)}: waiting for Launchpad archive deletion scheduled at "
            f"{scheduled} for {getattr(pub, 'source_package_version', '<unknown>')}"
        )

    if not active_publications:
        print(f"{pkg}: no Published/Superseded sources found")
        retained[pkg] = {}
        continue

    by_series = defaultdict(dict)
    for pub in active_publications:
        series = series_name(pub)
        version = str(getattr(pub, "source_package_version", "") or "")
        if not version:
            raise RuntimeError(f"{pkg}/{series}: source publication has no version")
        current = by_series[series].get(version)
        if current is None or status_priority.get(publication_status(pub), 0) > status_priority.get(publication_status(current), 0):
            by_series[series][version] = pub

    retained[pkg] = {}
    if pkg in reserve_packages:
        scope = ", ".join(sorted(reserve_series)) if reserve_series else "all series"
        print(
            f"{pkg}: reserving one of {keep_versions} retention slots for the impending upload "
            f"in {scope}"
        )

    for series, version_map in sorted(by_series.items()):
        reserve_for_series = pkg in reserve_packages and (
            not reserve_series or series in reserve_series
        )
        effective_keep = keep_versions - (1 if reserve_for_series else 0)
        effective_keep = max(0, effective_keep)
        versions = sorted(
            version_map,
            key=functools.cmp_to_key(debian_version_compare),
            reverse=True,
        )
        keep = versions[:effective_keep]
        drop = versions[effective_keep:]
        retained[pkg][series] = keep

        if keep:
            print(f"{pkg}/{series}: keeping newest {len(keep)} existing version(s): {', '.join(keep)}")
        elif reserve_for_series:
            print(f"{pkg}/{series}: no existing versions retained before upload")
        else:
            print(f"{pkg}/{series}: no existing versions retained")

        for version in drop:
            pub = version_map[version]
            status = publication_status(pub)
            scheduled = scheduled_deletion(pub)
            excess_publications += 1

            if dry_run:
                schedule_note = f" scheduled={scheduled}" if scheduled else ""
                print(f"{pkg}/{series}: would delete {version} status={status}{schedule_note}")
                continue

            if scheduled:
                print(
                    f"{pkg}/{series}: accelerating deletion of {version} status={status}; "
                    f"automatic deletion was scheduled for {scheduled}"
                )
            else:
                print(f"{pkg}/{series}: deleting {version} status={status}")

            retention_scope = (
                ", including one slot reserved for the impending upload"
                if reserve_for_series
                else ""
            )
            try:
                pub.requestDeletion(
                    removal_comment=(
                        "Automated PPA retention policy: keep at most "
                        f"{keep_versions} source version(s) for {pkg} in Ubuntu {series}"
                        f"{retention_scope}."
                    )
                )
                deleted += 1
            except Exception as exc:
                if scheduled:
                    already_scheduled += 1
                    print(
                        f"{pkg}/{series}: explicit deletion request for {version} was not accepted "
                        f"({exc}); existing scheduled deletion remains in effect"
                    )
                    continue
                raise

cleanup_pending = excess_publications > 0 or pending_deleted > 0
summary = {
    "schema": 1,
    "archive": f"ppa:{owner}/{archive}",
    "keep_versions": keep_versions,
    "reserve_packages": sorted(reserve_packages),
    "reserve_series": sorted(reserve_series),
    "packages": packages,
    "dry_run": dry_run,
    "deletion_requests": deleted,
    "already_scheduled": already_scheduled,
    "pending_deleted": pending_deleted,
    "terminal_deleted": terminal_deleted,
    "excess_publications": excess_publications,
    "cleanup_pending": cleanup_pending,
    "retained": retained,
}
print(json.dumps(summary, indent=2, sort_keys=True))
if result_json:
    pathlib.Path(result_json).write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

print(
    f"Done. deletion requests sent: {deleted}; already scheduled: {already_scheduled}; "
    f"deleted publications still scheduled: {pending_deleted}; terminal deleted history: "
    f"{terminal_deleted}; cleanup pending: {cleanup_pending}"
)
sys.exit(0)
PY
