# zkao Security Scan

A GitHub Action that launches a [zkao](https://zkao.io) security scan of the
commit a workflow is running on, waits for it, and reports the findings in the
job summary. It can fail the job when open findings reach a severity you pick.

```yaml
name: zkao
on:
  pull_request:
  push:
    branches: [main]

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: zksecurity/zkao-action@v1
        with:
          token: ${{ secrets.ZKAO_API_TOKEN }}
          project: ${{ vars.ZKAO_PROJECT_ID }}
          budget: 5000
          fail-on: high
```

The action needs no checkout: zkao reads the commit from GitHub itself.

## Before you start

1. Add the repository to a zkao project. Scans need at least one project
   member with GitHub access to the repository.
2. Create a project API token in the project's settings with the `read` and
   `scans:launch` scopes, and store it as the `ZKAO_API_TOKEN` secret.
3. Keep credits on the project. A scan reserves its budget at launch and is
   billed what it spends.

## Inputs

| Input | Required | Default | What it does |
| --- | --- | --- | --- |
| `token` | yes | | Project API token. Use a secret. |
| `project` | yes | | The zkao project id. |
| `budget` | yes | | Credit budget for the scan. |
| `repository` | | matched by name | The zkao repository id. By default the action finds the project repository whose owner and name match the workflow's repository. |
| `preset` | | project default | Scan type, as a preset ref such as `builtin:Quick Look` or `builtin:Deep Audit`. |
| `commit` | | see below | Commit to scan. |
| `branch` | | workflow branch | Branch the commit is on. Lets the scan reuse the branch's repository map. |
| `areas` | | whole repository | Comma-separated audit area keys to scope the scan to. |
| `guidance-file` | | | A file whose content replaces the repository's guidance for this scan. |
| `wait` | | `true` | Wait for the scan and report. `false` launches and returns. |
| `timeout` | | `10800` | Seconds to wait before giving up. The scan keeps running on zkao. |
| `fail-on` | | `none` | Fail the job when open findings reach this severity: `critical`, `high`, `medium`, `low`, `info`, or `none`. |
| `summary` | | `true` | Write the findings to the job summary. |
| `base-url` | | `https://zkao.io` | The zkao instance. |
| `cli-version` | | pinned | Version of `@zksecurity/zkao-cli` the action runs. |

On `pull_request` and `pull_request_target` events the action scans the head
of the pull request, since the merge commit GitHub builds for the workflow
only exists on the runner. On every other event it scans `github.sha`.

## Outputs

| Output | Meaning |
| --- | --- |
| `scan-id` | Id of the launched scan. |
| `scan-url` | The scan on zkao. |
| `status` | `COMPLETED`, `FAILED` or `CANCELLED` after waiting, `QUEUED` otherwise. |
| `findings-total` | Open findings: everything triage did not mark a false positive or a duplicate. |
| `findings-critical`, `findings-high`, `findings-medium`, `findings-low`, `findings-info` | Open findings by severity. |

Use them in later steps:

```yaml
      - uses: zksecurity/zkao-action@v1
        id: zkao
        with:
          token: ${{ secrets.ZKAO_API_TOKEN }}
          project: ${{ vars.ZKAO_PROJECT_ID }}
          budget: 5000
      - run: echo "${{ steps.zkao.outputs.findings-total }} open findings at ${{ steps.zkao.outputs.scan-url }}"
```

## Scoping and cost

A scan of the whole repository on every push adds up. Two ways to keep it in
check:

- Run on `pull_request` only, or gate the job on paths that matter.
- Pass `areas` to scan the audit areas the change touches. Area keys come
  from the repository's Context tab on zkao, or from `zkao areas list`.

A scan of a repository zkao is still analyzing waits for that analysis to
finish first.

## How it works

The action is a composite step that runs the published
[`@zksecurity/zkao-cli`](https://www.npmjs.com/package/@zksecurity/zkao-cli)
against the public API. Nothing is compiled or vendored: the CLI version is
pinned in `action.yml` and can be overridden with `cli-version`. The runner
needs `node` and `jq`, which every GitHub-hosted runner has.

## Releasing

Releases are GitHub releases with a semver tag (`v1.2.3`). Publishing one
re-points the major tag (`v1`) at it, so workflows pinned to `@v1` follow. Tick
"Publish this Action to the GitHub Marketplace" on the release form to update
the Marketplace listing.

## License

MIT, see [LICENSE](LICENSE).
