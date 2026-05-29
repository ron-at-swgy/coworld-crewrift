#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

DEFAULT_METTA_REPO="${REPO_ROOT}/../metta"
if [[ ! -d "${DEFAULT_METTA_REPO}/packages/coworld" && -d "${REPO_ROOT}/../thirdspace/metta/packages/coworld" ]]; then
  DEFAULT_METTA_REPO="${REPO_ROOT}/../thirdspace/metta"
fi
if [[ ! -d "${DEFAULT_METTA_REPO}/packages/coworld" && -d "/Users/relh/Code/thirdspace/metta/packages/coworld" ]]; then
  DEFAULT_METTA_REPO="/Users/relh/Code/thirdspace/metta"
fi

METTA_REPO="${METTA_REPO:-${DEFAULT_METTA_REPO}}"
COWORLD_SERVER="${COWORLD_SERVER:-https://softmax.com/api}"
CERTIFY_TIMEOUT="${CERTIFY_TIMEOUT:-180}"
GAME_IMAGE="public.ecr.aws/s3j4p9s7/treeform/games/crewrift:latest"
NOTSUS_IMAGE="public.ecr.aws/s3j4p9s7/treeform/players/notsus:latest"

VERSION=""
RUN_GIT_PULL=1
ALLOW_DIRTY=0
SKIP_TESTS=0
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  ./upload.sh VERSION [options]

Build and upload a Crewrift Coworld release from coworld-crewrift master.

Steps:
  1. git pull --ff-only and require a clean master checkout.
  2. Run the Nim test suite.
  3. Build linux/amd64 game and notsus images.
  4. Upload the Coworld through Metta's canonical coworld upload.

Options:
  --allow-dirty   Build from a dirty checkout.
  --no-pull       Do not git pull before building.
  --skip-tests    Do not run the Nim test suite.
  --skip-build    Do not rebuild local Docker images.
  -h, --help      Show this help.

Environment:
  METTA_REPO        Metta checkout used for uv run coworld.
  COWORLD_SERVER    Observatory API URL.
  CERTIFY_TIMEOUT   Coworld certifier timeout seconds.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-pull)
      RUN_GIT_PULL=0
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -n "${VERSION}" ]]; then
        die "Only one version argument is supported"
      fi
      VERSION="${1#v}"
      shift
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  usage
  exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
  die "Version must look like 0.1.22 or v0.1.22, got: ${VERSION}"
fi
if [[ ! -d "${METTA_REPO}/packages/coworld" ]]; then
  die "METTA_REPO does not look like a Metta checkout: ${METTA_REPO}"
fi

for cmd in git docker uv python3; do
  command -v "${cmd}" >/dev/null || die "Missing required command: ${cmd}"
done
if [[ "${SKIP_TESTS}" -eq 0 ]]; then
  command -v nim >/dev/null || die "Missing required command: nim"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crewrift-upload.${VERSION}.XXXXXX")"
UPLOAD_MANIFEST="${WORK_DIR}/coworld_manifest.json"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

metta_uv() {
  (cd "${METTA_REPO}" && uv run "$@")
}

coworld() {
  metta_uv coworld "$@"
}

require_master_checkout() {
  log "Refreshing coworld-crewrift master"
  local branch
  branch="$(git -C "${REPO_ROOT}" branch --show-current)"
  [[ "${branch}" == "master" ]] || die "Expected coworld-crewrift master, got ${branch:-detached HEAD}"

  if [[ "${RUN_GIT_PULL}" -eq 1 ]]; then
    run git -C "${REPO_ROOT}" pull --ff-only
  fi

  if [[ "${ALLOW_DIRTY}" -eq 0 ]]; then
    local status
    status="$(git -C "${REPO_ROOT}" status --porcelain)"
    [[ -z "${status}" ]] || die "Working tree is dirty. Commit/stash first or pass --allow-dirty."
  fi
}

prepare_manifest() {
  log "Preparing Coworld manifest ${VERSION}"
  VERSION="${VERSION}" python3 - "${REPO_ROOT}/coworld_manifest.json" "${UPLOAD_MANIFEST}" <<'PY'
import json
import os
import sys

source, target = sys.argv[1:]
with open(source, encoding="utf-8") as f:
    manifest = json.load(f)
manifest["game"]["version"] = os.environ["VERSION"]
with open(target, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

run_tests() {
  if [[ "${SKIP_TESTS}" -eq 1 ]]; then
    log "Skipping Nim tests"
    return
  fi
  log "Running Nim tests"
  run nim r "${REPO_ROOT}/tests/tests.nim"
}

build_images() {
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    log "Skipping Docker image builds"
    return
  fi

  log "Building Crewrift game image"
  run docker buildx build \
    --platform linux/amd64 \
    -f "${REPO_ROOT}/Dockerfile" \
    -t "${GAME_IMAGE}" \
    --load \
    "${REPO_ROOT}"

  log "Building notsus baseline player image"
  run docker buildx build \
    --platform linux/amd64 \
    -f "${REPO_ROOT}/players/notsus/Dockerfile" \
    -t "${NOTSUS_IMAGE}" \
    --load \
    "${REPO_ROOT}"
}

pull_manifest_images() {
  log "Pulling manifest images that are not built locally"
  python3 - "${UPLOAD_MANIFEST}" "${GAME_IMAGE}" "${NOTSUS_IMAGE}" <<'PY' | while IFS= read -r image; do
import json
import sys

manifest_path, game_image, notsus_image = sys.argv[1:]
built = {game_image, notsus_image}
with open(manifest_path, encoding="utf-8") as f:
    manifest = json.load(f)

def walk(value):
    if isinstance(value, dict):
        image = value.get("image")
        if isinstance(image, str) and image not in built:
            print(image)
        for item in value.values():
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)

walk(manifest)
PY
    run docker pull "${image}"
  done
}

upload_coworld() {
  log "Certifying and uploading Coworld"
  local upload_log="${WORK_DIR}/upload-coworld.log"
  set +e
  coworld upload-coworld \
    "${UPLOAD_MANIFEST}" \
    --server "${COWORLD_SERVER}" \
    --timeout-seconds "${CERTIFY_TIMEOUT}" 2>&1 | tee "${upload_log}"
  local upload_status="${PIPESTATUS[0]}"
  set -e
  [[ "${upload_status}" -eq 0 ]] || die "coworld upload-coworld failed. See ${upload_log}"

  local coworld_id
  coworld_id="$(awk '/^Coworld:/ {print $2}' "${upload_log}" | tail -1)"
  if [[ -n "${coworld_id}" ]]; then
    log "Verifying uploaded Coworld ${coworld_id}"
    coworld show "${coworld_id}" --server "${COWORLD_SERVER}" --json
  fi
}

require_master_checkout
prepare_manifest
run_tests
build_images
pull_manifest_images
upload_coworld

log "Crewrift ${VERSION} upload flow complete"
