#!/usr/bin/env bash
# Launch a zkao scan of one commit; optionally wait for it and gate on it.
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

case "${INPUT_MODE}" in
  launch|wait|gate) ;;
  *) fail "Unknown mode '${INPUT_MODE}'. Use launch, wait, or gate." ;;
esac

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
# Which scan. A kind name maps to its builtin preset; anything else is passed
# through as a preset ref. A diff scan is a quick look steered at the change:
# the public API has no diff scope yet, so the changed files go in as guidance
# on top of the repository's own.
# ---------------------------------------------------------------------------
scan="$(printf '%s' "${INPUT_SCAN}" | tr '[:upper:]' '[:lower:]')"
preset=""
diff_scan=0
case "${scan}" in
  quick-look|quicklook|"quick look") preset="builtin:Quick Look" ;;
  deep-audit|deepaudit|"deep audit"|audit) preset="builtin:Deep Audit" ;;
  diff|diff-scan) preset="builtin:Quick Look"; diff_scan=1 ;;
  "") ;;
  *) preset="${INPUT_SCAN}" ;;
esac

guidance_file="${INPUT_GUIDANCE_FILE}"
if [ "${diff_scan}" -eq 1 ]; then
  base="${INPUT_BASE}"
  if [ -z "${base}" ]; then
    case "${GITHUB_EVENT_NAME:-}" in
      pull_request|pull_request_target)
        base="$(jq -r '.pull_request.base.sha // empty' "${GITHUB_EVENT_PATH}")"
        ;;
      push)
        base="$(jq -r '.before // empty' "${GITHUB_EVENT_PATH}")"
        ;;
    esac
  fi
  [ -n "${base}" ] || fail "A diff scan needs the commit the change is measured from. Pass the base input."
  if [[ "${base}" =~ ^0+$ ]]; then
    fail "This push created the branch, so there is no earlier commit to diff against. Pass the base input."
  fi

  compare="$(curl -sS --fail \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/compare/${base}...${commit}?per_page=300")" \
    || fail "Could not read the change ${base:0:12}...${commit:0:12} from GitHub."
  changed_files="$(printf '%s' "${compare}" | jq -r '.files[]?.filename')"
  commit_count="$(printf '%s' "${compare}" | jq -r '.total_commits // 0')"
  if [ -z "${changed_files}" ]; then
    fail "Nothing changed between ${base:0:12} and ${commit:0:12}, so there is nothing for a diff scan to read."
  fi

  guidance_file="${RUNNER_TEMP:-/tmp}/zkao-diff-guidance.md"
  {
    if [ -n "${INPUT_GUIDANCE_FILE}" ]; then
      cat "${INPUT_GUIDANCE_FILE}"
    else
      # The repository's own guidance still applies underneath the scope: a
      # per-scan guidance replaces it, so it is carried over by hand.
      zkao guidance get "${repository_id}" | jq -r '.content // empty'
    fi
    printf '\n\n## Scope: the change between %s and %s\n\n' "${base:0:12}" "${commit:0:12}"
    printf 'This scan is about the %s commit(s) added since %s. ' "${commit_count}" "${base:0:12}"
    printf 'Only the files below changed. Read the rest of the repository as context for them, not as a target.\n\n'
    printf '%s\n' "${changed_files}" | sed 's/^/- /'
  } >"${guidance_file}"
  echo "Diff scan: ${commit_count} commit(s), $(printf '%s\n' "${changed_files}" | wc -l | tr -d ' ') changed file(s) since ${base:0:12}."
fi

# ---------------------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------------------
args=(scans launch --repo "${repository_id}" --budget "${INPUT_BUDGET}" --commit "${commit}")
[ -n "${branch}" ] && args+=(--branch "${branch}")
[ -n "${preset}" ] && args+=(--preset "${preset}")
[ -n "${guidance_file}" ] && args+=(--guidance "${guidance_file}")
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
label="${scan:-scan}"
[ "${diff_scan}" -eq 1 ] && label="diff scan (a quick look steered at the change)"

{
  echo "scan-id=${scan_id}"
  echo "scan-url=${scan_url}"
} >>"${GITHUB_OUTPUT}"
echo "Launched ${label} ${scan_id} of ${commit:0:12}: ${scan_url}"

if [ "${INPUT_MODE}" = "launch" ]; then
  echo "status=QUEUED" >>"${GITHUB_OUTPUT}"
  if [ "${INPUT_SUMMARY}" = "true" ]; then
    printf '## zkao scan launched\n\n[Scan %s](%s) of `%s` is queued: %s. The workflow does not wait for it.\n' \
      "${scan_id}" "${scan_url}" "${commit:0:12}" "${label}" >>"${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Wait, then read the findings.
# ---------------------------------------------------------------------------
final="$(zkao scans wait "${scan_id}" --timeout "${INPUT_TIMEOUT}")"
status="$(printf '%s' "${final}" | jq -r '.status // .scan.status // empty')"
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
        | "| \(.severity) | [ZK-\(.displayId) \(.title | gsub("\\|"; "\\|"))](\($base)/projects/\($project)/findings?finding=\(.id)) | `\(.location // "")` | \(.triageStatus) |"'
      printf '\n'
    fi
  } >>"${GITHUB_STEP_SUMMARY}"
fi

if [ "${INPUT_MODE}" != "gate" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------
threshold="$(printf '%s' "${INPUT_FAIL_ON}" | tr '[:upper:]' '[:lower:]')"
gated=0
case "${threshold}" in
  critical) gated=$((critical)) ;;
  high) gated=$((critical + high)) ;;
  medium) gated=$((critical + high + medium)) ;;
  low) gated=$((critical + high + medium + low)) ;;
  info|none) gated=$((open_total)) ;;
  *) fail "Unknown fail-on value '${INPUT_FAIL_ON}'. Use critical, high, medium, low, or info." ;;
esac
if [ "${gated}" -gt 0 ]; then
  fail "${gated} open finding(s) at or above ${threshold} severity: ${scan_url}"
fi
