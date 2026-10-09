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
  # `zkao repos` returns a bare array; older CLIs wrapped it in
  # `{repositories: [...]}`. Accept either so one action serves both.
  repos="$(zkao repos | jq 'if type == "array" then . else .repositories end')"
  repository_id="$(
    printf '%s' "${repos}" | jq -r --arg owner "${owner}" --arg name "${name}" '
      .[]
      | select((.owner | ascii_downcase) == ($owner | ascii_downcase)
           and (.name | ascii_downcase) == ($name | ascii_downcase))
      | .id' | head -n 1
  )"
  if [ -z "${repository_id}" ]; then
    fail "No repository named ${GITHUB_REPOSITORY} in zkao project ${ZKAO_PROJECT_ID}. Add it to the project, or pass the zkao repository id as the repository input."
  fi
  readiness="$(printf '%s' "${repos}" | jq -r --arg id "${repository_id}" '.[] | select(.id == $id) | .readiness')"
  if [ "${readiness}" = "analyzing" ]; then
    echo "zkao is still analyzing ${GITHUB_REPOSITORY}; waiting for that to finish."
    zkao repos:wait "${repository_id}" >/dev/null
  fi
fi

# ---------------------------------------------------------------------------
# Which pull request, if any. Needed to comment, and on an issue_comment event
# it is the only way to learn which commits the pull request spans: that event
# carries no SHAs, and the workflow runs on the default branch, so GITHUB_SHA
# points at the wrong code.
# ---------------------------------------------------------------------------
gh_api() {
  curl -sS --fail \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}$1"
}

# Comment on the pull request. Never fatal: a missing permission must not fail
# a job whose scan ran fine.
post_comment() {
  [ "${INPUT_COMMENT}" = "true" ] || return 0
  if [ -z "${pr_number}" ]; then
    echo "::warning::comment is on but this event has no pull request to comment on."
    return 0
  fi
  jq -n --arg body "$1" '{body: $body}' | curl -sS --fail -o /dev/null \
    -X POST \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    --data @- \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" \
    || echo "::warning::Could not comment on #${pr_number}. The job needs permissions: pull-requests: write."
}

# Always answer a command, even when `comment` is off: a person who typed one
# is owed a reply.
reply() {
  local saved="${INPUT_COMMENT}"
  INPUT_COMMENT=true
  post_comment "$1"
  INPUT_COMMENT="${saved}"
}

usage_text() {
  cat <<EOF
**zkao** takes commands in a pull request comment.

| Command | What it does |
| --- | --- |
| \`${INPUT_MENTION} /scan\` | Audit this pull request's change (${INPUT_SCAN}). |
| \`${INPUT_MENTION} /scan <kind>\` | Audit it as \`diff\`, \`quick-look\` or \`deep-audit\`. |
| \`${INPUT_MENTION} /help\` | Show this. |

A scan reports back here when it finishes. Only the repository's owner, members and collaborators can start one.
EOF
}

pr_number=""
pr_head=""
pr_base=""
pr_base_ref=""
pr_head_ref=""
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target)
    pr_number="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}")"
    pr_head="$(jq -r '.pull_request.head.sha // empty' "${GITHUB_EVENT_PATH}")"
    pr_base="$(jq -r '.pull_request.base.sha // empty' "${GITHUB_EVENT_PATH}")"
    pr_base_ref="$(jq -r '.pull_request.base.ref // empty' "${GITHUB_EVENT_PATH}")"
    pr_head_ref="$(jq -r '.pull_request.head.ref // empty' "${GITHUB_EVENT_PATH}")"
    ;;
  issue_comment)
    if [ "$(jq -r 'if .issue.pull_request then "pr" else "issue" end' "${GITHUB_EVENT_PATH}")" != "pr" ]; then
      echo "This comment is on an issue, not a pull request; nothing to scan."
      exit 0
    fi
    # Only someone who can already push or review may spend the project's
    # credits. Without this, any passer-by could launch scans by commenting on
    # a public repository.
    association="$(jq -r '.comment.author_association // empty' "${GITHUB_EVENT_PATH}")"
    case "${association}" in
      OWNER|MEMBER|COLLABORATOR) ;;
      *)
        echo "Ignoring a comment from ${association:-an outside account}: only the repository's owner, members and collaborators can start a scan."
        exit 0
        ;;
    esac
    pr_number="$(jq -r '.issue.number // empty' "${GITHUB_EVENT_PATH}")"
    [ -n "${pr_number}" ] || fail "Could not read the pull request number from the comment event."
    pr="$(gh_api "/repos/${GITHUB_REPOSITORY}/pulls/${pr_number}")" \
      || fail "Could not read pull request #${pr_number} from GitHub."
    pr_head="$(printf '%s' "${pr}" | jq -r '.head.sha // empty')"
    pr_base="$(printf '%s' "${pr}" | jq -r '.base.sha // empty')"
    pr_base_ref="$(printf '%s' "${pr}" | jq -r '.base.ref // empty')"
    pr_head_ref="$(printf '%s' "${pr}" | jq -r '.head.ref // empty')"
    comment_id="$(jq -r '.comment.id // empty' "${GITHUB_EVENT_PATH}")"

    # What was asked. Everything after the mention on its line: the first word
    # is the command, the second its argument.
    body="$(jq -r '.comment.body // ""' "${GITHUB_EVENT_PATH}" | tr '\r\n' '  ')"
    after="$(printf '%s' "${body}" | grep -oiE "${INPUT_MENTION}.*" | head -n 1 || true)"
    set -f
    # shellcheck disable=SC2086  # deliberate word split of the comment text
    set -- ${after}
    set +f
    shift || true
    comment_command="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    comment_arg="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"

    case "${comment_command}" in
      /scan)
        # An explicit kind overrides the workflow's default.
        if [ -n "${comment_arg}" ]; then
          INPUT_SCAN="${comment_arg}"
        fi
        ;;
      /help|"")
        # A bare mention is a question, not an order. Answering instead of
        # scanning keeps a passing reference from spending the project's credits.
        reply "$(usage_text)"
        exit 0
        ;;
      /*)
        reply "$(printf '**zkao** does not know \`%s\`. Try \`%s /help\`.' "${comment_command}" "${INPUT_MENTION}")"
        exit 0
        ;;
      *)
        # Prose, not an instruction: someone mentioned zkao in conversation.
        # Saying nothing beats answering a sentence that was not addressed here.
        echo "Mentioned without a command; nothing to do."
        exit 0
        ;;
    esac
    ;;
  push)
    # A push carries no pull request. When the pushed branch has one open,
    # comment there anyway: the scan is about that change either way.
    if [ "${INPUT_COMMENT}" = "true" ] && [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then
      pushed_branch="${GITHUB_REF#refs/heads/}"
      owner="${GITHUB_REPOSITORY%%/*}"
      pr_number="$(
        gh_api "/repos/${GITHUB_REPOSITORY}/pulls?state=open&head=${owner}:${pushed_branch}" \
          | jq -r '.[0].number // empty'
      )" || pr_number=""
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Which commit. A pull request's github.sha is the merge commit GitHub built,
# which the scan cannot read, so the head of the pull request is scanned.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2153  # INPUT_COMMIT is an action input, not a typo for INPUT_COMMENT
commit="${INPUT_COMMIT}"
if [ -z "${commit}" ]; then
  commit="${pr_head:-${GITHUB_SHA:-}}"
fi
[ -n "${commit}" ] || fail "Could not determine the commit to scan. Pass the commit input."

branch="${INPUT_BRANCH}"
if [ -z "${branch}" ]; then
  if [ -n "${pr_head_ref}" ]; then
    branch="${pr_head_ref}"
  elif [ -n "${GITHUB_HEAD_REF:-}" ]; then
    branch="${GITHUB_HEAD_REF}"
  elif [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then
    branch="${GITHUB_REF#refs/heads/}"
  fi
fi


# ---------------------------------------------------------------------------
# Which scan. A kind name maps to its builtin preset; anything else is passed
# through as a preset ref. A diff scan audits only the change since its base.
# ---------------------------------------------------------------------------
scan="$(printf '%s' "${INPUT_SCAN}" | tr '[:upper:]' '[:lower:]')"
preset=""
base=""
case "${scan}" in
  quick-look|quicklook|"quick look") preset="builtin:Quick Look" ;;
  deep-audit|deepaudit|"deep audit"|audit) preset="builtin:Deep Audit" ;;
  diff|diff-scan) preset="builtin:Diff Scan" ;;
  "") ;;
  *) preset="${INPUT_SCAN}" ;;
esac

if [ "${preset}" = "builtin:Diff Scan" ]; then
  base="${INPUT_BASE}"
  if [ -z "${base}" ]; then
    base="${pr_base}"
  fi
  if [ -z "${base}" ]; then
    case "${GITHUB_EVENT_NAME:-}" in
      push)
        base="$(jq -r '.before // empty' "${GITHUB_EVENT_PATH}")"
        ;;
    esac
  fi
  [ -n "${base}" ] || fail "A diff scan needs the commit the change is measured from. Pass the base input."
  if [[ "${base}" =~ ^0+$ ]]; then
    fail "This push created the branch, so there is no earlier commit to diff against. Pass the base input."
  fi
  # A diff scan reads the change against the map of the branch it is going to
  # land on, so on a pull request the branch is the target, not the topic
  # branch. Sending the topic branch would build a throw-away map per branch.
  if [ -z "${INPUT_BRANCH}" ] && [ -n "${pr_base_ref}" ]; then
    branch="${pr_base_ref}"
  fi
fi

# ---------------------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------------------
args=(scans launch --repo "${repository_id}" --commit "${commit}")
[ -n "${INPUT_BUDGET}" ] && args+=(--budget "${INPUT_BUDGET}")
[ -n "${branch}" ] && args+=(--branch "${branch}")
[ -n "${preset}" ] && args+=(--preset "${preset}")
[ -n "${base}" ] && args+=(--base "${base}")
# Where this came from, so the scan page can link back here. References only:
# zkao builds the link from the repository it is scanning.
case "${GITHUB_EVENT_NAME:-}" in
  issue_comment) args+=(--trigger pr_comment) ;;
  *) args+=(--trigger github_action) ;;
esac
[ -n "${pr_number}" ] && args+=(--pull-request "${pr_number}")
[ -n "${comment_id:-}" ] && args+=(--comment-id "${comment_id}")
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
budget="$(printf '%s' "${launched}" | jq -r '.creditBudget // empty')"
scan_url="${INPUT_BASE_URL%/}/projects/${ZKAO_PROJECT_ID}/scans/${scan_id}"
label="${scan:-scan}"
[ -n "${base}" ] && label="diff scan since ${base:0:12}"

{
  echo "scan-id=${scan_id}"
  echo "scan-url=${scan_url}"
} >>"${GITHUB_OUTPUT}"
echo "Launched ${label} ${scan_id} of ${commit:0:12}${budget:+ with a budget of ${budget} credits}: ${scan_url}"

post_comment "$(printf '**zkao** is scanning `%s` ([%s](%s)).\n\nResults will follow here.' \
  "${commit:0:12}" "${label}" "${scan_url}")"

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
  post_comment "$(printf '**zkao** scan of `%s` ended as %s. [See the scan](%s).' \
    "${commit:0:12}" "${status}" "${scan_url}")"
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

# Counts and a link, never the findings themselves: on a public repository a
# comment would disclose unfixed vulnerabilities to everyone who can read it.
if [ "${open_total}" -gt 0 ]; then
  post_comment "$(printf '**zkao** found **%s open finding(s)** in `%s`: critical %s, high %s, medium %s, low %s, info %s.\n\n[Read them on zkao](%s).' \
    "${open_total}" "${commit:0:12}" "${critical}" "${high}" "${medium}" "${low}" "${info}" "${scan_url}")"
else
  post_comment "$(printf '**zkao** found no open findings in `%s`. [See the scan](%s).' \
    "${commit:0:12}" "${scan_url}")"
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
