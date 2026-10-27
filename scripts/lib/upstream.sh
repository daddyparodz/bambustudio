#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "$*" >&2
  exit 1
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

fetch_release_feed() {
  local api_url="https://api.github.com/repos/bambulab/BambuStudio/releases?per_page=100"
  local -a curl_args=(-fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl "${curl_args[@]}" "$api_url"
}

latest_release_json() {
  local channel="${1:-stable}"
  local json
  json="$(fetch_release_feed)"

  case "$channel" in
    stable)
      jq -c 'map(select(.prerelease == false and .draft == false)) | first? // empty' <<<"$json"
      ;;
    beta)
      jq -c 'map(select(.prerelease == true and .draft == false)) | first? // empty' <<<"$json"
      ;;
    *)
      die "Unknown channel: $channel"
      ;;
  esac
}

release_json_for_tag() {
  local tag="$1"
  local json
  json="$(fetch_release_feed)"
  jq -c --arg tag "$tag" 'map(select(.tag_name == $tag and .draft == false)) | first? // empty' <<<"$json"
}

release_version_from_tag() {
  local tag="$1"
  printf '%s\n' "${tag#v}"
}

series_version_suffix() {
  local series="$1"
  local version
  version="$(ubuntu-distro-info --series="$series" -r 2>/dev/null || true)"
  if [[ -z "$version" ]]; then
    die "Unsupported Ubuntu series: $series"
  fi
  printf '%s\n' "$version" | awk '{print $1}'
}

preferred_asset_series() {
  local series="$1"
  local version major
  version="$(series_version_suffix "$series")"
  major="${version%%.*}"
  if (( major >= 24 )); then
    printf '24.04\n'
  else
    printf '22.04\n'
  fi
}

fallback_asset_series() {
  local series="$1"
  local primary
  primary="$(preferred_asset_series "$series")"
  if [[ "$primary" == "24.04" ]]; then
    printf '22.04\n'
  else
    printf '24.04\n'
  fi
}

appimage_asset_url() {
  local release_json="$1"
  local series="$2"
  local primary fallback url

  primary="$(preferred_asset_series "$series")"
  fallback="$(fallback_asset_series "$series")"

  url="$(jq -r '.assets[]?.browser_download_url' <<<"$release_json" | grep -E "BambuStudio_(ubuntu[-_]?${primary}|ubu${primary%%.*})-.*\\.AppImage$" | head -n1 || true)"
  if [[ -z "$url" ]]; then
    url="$(jq -r '.assets[]?.browser_download_url' <<<"$release_json" | grep -E "BambuStudio_(ubuntu[-_]?${fallback}|ubu${fallback%%.*})-.*\\.AppImage$" | head -n1 || true)"
  fi

  if [[ -z "$url" ]]; then
    die "No compatible AppImage asset found for Ubuntu series ${series}"
  fi

  printf '%s\n' "$url"
}
