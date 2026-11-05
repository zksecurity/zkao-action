#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"

cat >"$test_dir/bin/npx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$ACTION_TEST_DIR/cli.log"
case "$3 $4" in
  'scans launch') printf '%s\n' '{"scanId":"scan-1","creditBudget":1000,"buildsOverview":true}' ;;
  'scans wait') printf '%s\n' '{"status":"COMPLETED"}' ;;
  'findings list') printf '%s\n' '{"items":[],"total":0}' ;;
  *) echo "Unexpected CLI invocation: $*" >&2; exit 1 ;;
esac
MOCK
cat >"$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -c . >>"$ACTION_TEST_DIR/comments.jsonl"
MOCK
chmod +x "$test_dir/bin/npx" "$test_dir/bin/curl"
cat >"$test_dir/event.json" <<'JSON'
{"pull_request":{"number":1,"head":{"sha":"0123456789abcdef","ref":"topic"},"base":{"sha":"abcdef0123456789","ref":"main"}}}
JSON

for mode in launch wait gate; do
  run_dir="$test_dir/$mode"
  mkdir "$run_dir"
  env PATH="$test_dir/bin:$PATH" ACTION_TEST_DIR="$run_dir" \
    INPUT_MODE="$mode" INPUT_REPOSITORY="repo-1" INPUT_CLI_VERSION="test" \
    INPUT_COMMENT="true" INPUT_GITHUB_TOKEN="fake" INPUT_MENTION="/zkao" \
    INPUT_COMMIT="" INPUT_BRANCH="" INPUT_SCAN="flash" INPUT_BASE="" \
    INPUT_BUDGET="1000" INPUT_GUIDANCE_FILE="" INPUT_AREAS="" \
    INPUT_BASE_URL="https://zkao.example" INPUT_SUMMARY="true" \
    INPUT_TIMEOUT="1" INPUT_FAIL_ON="high" ZKAO_PROJECT_ID="project-1" \
    GITHUB_EVENT_NAME="pull_request" GITHUB_EVENT_PATH="$test_dir/event.json" \
    GITHUB_REPOSITORY="owner/repo" GITHUB_OUTPUT="$run_dir/output" \
    GITHUB_STEP_SUMMARY="$run_dir/summary" \
    bash "$script_dir/scan.sh" >"$run_dir/stdout" || exit 1
  first_comment="$(head -n 1 "$run_dir/comments.jsonl" | jq -r .body)"
  [[ "$first_comment" == *'so this scan builds one first.'* ]] || exit 1
  grep -q '^::notice::No earlier scan' "$run_dir/stdout" || exit 1
  if [ "$mode" = launch ]; then
    [[ "$first_comment" == *'Follow the scan link for results.'* ]] || exit 1
    [[ "$first_comment" != *'Results will follow here.'* ]] || exit 1
    [ "$(wc -l <"$run_dir/comments.jsonl" | tr -d ' ')" = 1 ] || exit 1
    ! grep -q 'scans wait' "$run_dir/cli.log" || exit 1
  else
    [[ "$first_comment" == *'Results will follow here.'* ]] || exit 1
    [ "$(wc -l <"$run_dir/comments.jsonl" | tr -d ' ')" = 2 ] || exit 1
    tail -n 1 "$run_dir/comments.jsonl" | jq -e '.body | contains("found no open findings")' >/dev/null || exit 1
  fi
  printf 'PASS %s comment lifecycle\n' "$mode"
done

# A budget below the minimum fails the job with the minimum and what to do.
cat >"$test_dir/bin/npx" <<'MOCK'
#!/usr/bin/env bash
echo "Error 400 (budget_below_minimum): This scan requires a minimum budget of 1,929 credits. No earlier scan of this repository built its overview, so this scan builds one first." >&2
exit 1
MOCK
run_dir="$test_dir/below-minimum"
mkdir "$run_dir"
if env PATH="$test_dir/bin:$PATH" ACTION_TEST_DIR="$run_dir" \
  INPUT_MODE=launch INPUT_REPOSITORY="repo-1" INPUT_CLI_VERSION="test" \
  INPUT_COMMENT="false" INPUT_GITHUB_TOKEN="fake" INPUT_MENTION="/zkao" \
  INPUT_COMMIT="" INPUT_BRANCH="" INPUT_SCAN="flash" INPUT_BASE="" \
  INPUT_BUDGET="1000" INPUT_GUIDANCE_FILE="" INPUT_AREAS="" \
  INPUT_BASE_URL="https://zkao.example" INPUT_SUMMARY="false" \
  INPUT_TIMEOUT="1" INPUT_FAIL_ON="high" ZKAO_PROJECT_ID="project-1" \
  GITHUB_EVENT_NAME="pull_request" GITHUB_EVENT_PATH="$test_dir/event.json" \
  GITHUB_REPOSITORY="owner/repo" GITHUB_OUTPUT="$run_dir/output" \
  GITHUB_STEP_SUMMARY="$run_dir/summary" \
  bash "$script_dir/scan.sh" >"$run_dir/stdout" 2>&1; then
  exit 1
fi
grep -q '^::error::This scan requires a minimum budget of 1,929 credits\..*Raise the budget input to at least that' "$run_dir/stdout" || exit 1
printf 'PASS budget below the minimum\n'
