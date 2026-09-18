#!/usr/bin/env bash
# Launch a zkao scan of one commit, optionally wait for it, and report.
#
# Runs the published zkao CLI, so every call here is one the CLI documents.
# The CLI prints JSON on stdout and progress on stderr; jq reads the former.
# shellcheck disable=SC2016  # backticks below are Markdown, not command substitution
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required and was not found on this runner."
  exit 1
fi

zkao() {
  npx --yes "@zksecurity/zkao-cli@${INPUT_CLI_VERSION}" "$@"
}

fail() {
  echo "::error::$1"
  exit 1
}

# ---------------------------------------------------------------------------
# Which zkao repository this GitHub repository is.
# ---------------------------------------------------------------------------
repository_id="${INPUT_REPOSITORY}"
if [ -z "${repository_id}" ]; then
  owner="${GITHUB_REPOSITORY%%/*}"
  name="${GITHUB_REPOSITORY#*/}"
  repos="$(zkao repos)"
  repository_id="$(
    printf '%s' "${repos}" | jq -r --arg owner "${owner}" --arg name "${name}" '
      .repositories[]
      | select((.owner | ascii_downcase) == ($owner | ascii_downcase)
           and (.name | ascii_downcase) == ($name | ascii_downcase))
      | .id' | head -n 1
  )"
  if [ -z "${repository_id}" ]; then
    fail "No repository named ${GITHUB_REPOSITORY} in zkao project ${ZKAO_PROJECT_ID}. Add it to the project, or pass the zkao repository id as the repository input."
  fi
  readiness="$(printf '%s' "${repos}" | jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .readiness')"
  if [ "${readiness}" = "analyzing" ]; then
    echo "zkao is still analyzing ${GITHUB_REPOSITORY}; waiting for that to finish."
    zkao repos:wait "${repository_id}" >/dev/null
  fi
fi

# ---------------------------------------------------------------------------
# Which commit. A pull request's github.sha is the merge commit GitHub built,
# which the scan cannot read, so the head of the pull request is scanned.
# ---------------------------------------------------------------------------
commit="${INPUT_COMMIT}"
if [ -z "${commit}" ]; then
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request|pull_request_target)
      commit="$(jq -r '.pull_request.head.sha // empty' "${GITHUB_EVENT_PATH}")"
      ;;
  esac
  commit="${commit:-${GITHUB_SHA:-}}"
fi
[ -n "${commit}" ] || fail "Could not determine the commit to scan. Pass the commit input."

branch="${INPUT_BRANCH}"
if [ -z "${branch}" ]; then
  if [ -n "${GITHUB_HEAD_REF:-}" ]; then
    branch="${GITHUB_HEAD_REF}"
  elif [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then
    branch="${GITHUB_REF#refs/heads/}"
  fi
fi

# ---------------------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------------------
args=(scans launch --repo "${repository_id}" --budget "${INPUT_BUDGET}" --commit "${commit}")
[ -n "${branch}" ] && args+=(--branch "${branch}")
[ -n "${INPUT_PRESET}" ] && args+=(--preset "${INPUT_PRESET}")
[ -n "${INPUT_GUIDANCE_FILE}" ] && args+=(--guidance "${INPUT_GUIDANCE_FILE}")
if [ -n "${INPUT_AREAS}" ]; then
  IFS=',' read -r -a areas <<<"${INPUT_AREAS}"
  for area in "${areas[@]}"; do
    area="$(printf '%s' "${area}" | xargs)"
    [ -n "${area}" ] && args+=(--area "${area}")
  done
fi

launched="$(zkao "${args[@]}")"
scan_id="$(printf '%s' "${launched}" | jq -r '.scanId // empty')"
[ -n "${scan_id}" ] || fail "The launch returned no scan id: ${launched}"
scan_url="${INPUT_BASE_URL%/}/projects/${ZKAO_PROJECT_ID}/scans/${scan_id}"

{
  echo "scan-id=${scan_id}"
  echo "scan-url=${scan_url}"
} >>"${GITHUB_OUTPUT}"
echo "Launched scan ${scan_id} of ${commit:0:12}: ${scan_url}"

if [ "${INPUT_WAIT}" != "true" ]; then
  echo "status=QUEUED" >>"${GITHUB_OUTPUT}"
  if [ "${INPUT_SUMMARY}" = "true" ]; then
    printf '## zkao scan launched\n\n[Scan %s](%s) of `%s` is queued.\n' "${scan_id}" "${scan_url}" "${commit:0:12}" >>"${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Wait, then read the findings.
# ---------------------------------------------------------------------------
scan="$(zkao scans wait "${scan_id}" --timeout "${INPUT_TIMEOUT}")"
status="$(printf '%s' "${scan}" | jq -r '.status // .scan.status // empty')"
echo "status=${status}" >>"${GITHUB_OUTPUT}"

if [ "${status}" != "COMPLETED" ]; then
  if [ "${INPUT_SUMMARY}" = "true" ]; then
    printf '## zkao scan %s\n\n[Scan %s](%s) of `%s` ended as %s.\n' "${status}" "${scan_id}" "${scan_url}" "${commit:0:12}" "${status}" >>"${GITHUB_STEP_SUMMARY}"
  fi
  fail "Scan ${scan_id} ended as ${status}: ${scan_url}"
fi

# Every page of findings. Closed ones (false positives, duplicates) are
# listed but not counted: the gate is about what is still open.
findings='[]'
page=1
while :; do
  chunk="$(zkao findings list --scan "${scan_id}" --page "${page}" --limit 100)"
  findings="$(jq -n --argjson acc "${findings}" --argjson chunk "${chunk}" '$acc + $chunk.items')"
  total="$(printf '%s' "${chunk}" | jq -r '.total // 0')"
  if [ "$((page * 100))" -ge "${total}" ]; then
    break
  fi
  page=$((page + 1))
done

open="$(printf '%s' "${findings}" | jq '
  map(select(
    (.triageStatus != "FALSE_POSITIVE" and .triageStatus != "DUPLICATE")
    and (.resolutionStatus != "FALSE_POSITIVE" and .resolutionStatus != "DUPLICATE")
  ))')"

count() {
  printf '%s' "${open}" | jq --arg sev "$1" '[.[] | select(.severity == $sev)] | length'
}
critical="$(count CRITICAL)"
high="$(count HIGH)"
medium="$(count MEDIUM)"
low="$(count LOW)"
info="$(count INFO)"
open_total="$(printf '%s' "${open}" | jq 'length')"

{
  echo "findings-total=${open_total}"
  echo "findings-critical=${critical}"
  echo "findings-high=${high}"
  echo "findings-medium=${medium}"
  echo "findings-low=${low}"
  echo "findings-info=${info}"
} >>"${GITHUB_OUTPUT}"

echo "Scan ${scan_id} completed: ${open_total} open finding(s) (critical ${critical}, high ${high}, medium ${medium}, low ${low}, info ${info})."

if [ "${INPUT_SUMMARY}" = "true" ]; then
  {
    printf '## zkao scan completed\n\n'
    printf '[Scan %s](%s) of `%s`: **%s open finding(s)**' "${scan_id}" "${scan_url}" "${commit:0:12}" "${open_total}"
    printf ' (critical %s, high %s, medium %s, low %s, info %s).\n\n' "${critical}" "${high}" "${medium}" "${low}" "${info}"
    if [ "${open_total}" -gt 0 ]; then
      printf '| Severity | Finding | Location | Triage |\n|---|---|---|---|\n'
      printf '%s' "${open}" | jq -r --arg base "${INPUT_BASE_URL%/}" --arg project "${ZKAO_PROJECT_ID}" '
        def rank: {CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, INFO: 4}[.severity] // 5;
        sort_by(rank)[]
        | "| \(.severity) | [ZK-\(.displayId) \(.title | gsub("\\|"; "\\\\|"))](\($base)/projects/\($project)/findings?finding=\(.id)) | `\(.location // "")` | \(.triageStatus) |"'
      printf '\n'
    fi
  } >>"${GITHUB_STEP_SUMMARY}"
fi

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------
threshold="$(printf '%s' "${INPUT_FAIL_ON}" | tr '[:upper:]' '[:lower:]')"
gated=0
case "${threshold}" in
  none) ;;
  critical) gated=$((critical)) ;;
  high) gated=$((critical + high)) ;;
  medium) gated=$((critical + high + medium)) ;;
  low) gated=$((critical + high + medium + low)) ;;
  info) gated=$((open_total)) ;;
  *) fail "Unknown fail-on value '${INPUT_FAIL_ON}'. Use critical, high, medium, low, info, or none." ;;
esac
if [ "${gated}" -gt 0 ]; then
  fail "${gated} open finding(s) at or above ${threshold} severity: ${scan_url}"
fi
