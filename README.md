# zkao Security Scan

A GitHub Action that launches a [zkao](https://zkao.io) security scan of the
commit a workflow is running on. By default it starts the scan and returns;
ask it to wait and it reports the findings in the job summary, and it can
fail the job when open findings reach a severity you pick.

```yaml
name: zkao
on:
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
```

That launches a quick look of every push to `main` and moves on; the
results are on zkao when the scan finishes. The scan runs at the budget zkao
recommends for the repository, and the action needs no checkout: zkao reads
the commit from GitHub itself.

## Before you start

1. Add the repository to a zkao project. Scans need at least one project
   member with GitHub access to the repository.
2. Create a project API token in the project's settings with the `read` and
   `scans:launch` scopes, and store it as the `ZKAO_API_TOKEN` secret.
3. Keep credits on the project. A scan reserves its budget at launch and is
   billed what it spends. The budget defaults to what zkao recommends for the
   scan type on the repository, sized from past runs; pass `budget` to cap it
   yourself.

## Three modes

| `mode` | What happens |
| --- | --- |
| `launch` (default) | Starts the scan and returns. The job never waits or fails on findings. |
| `wait` | Waits for the scan and writes the findings to the job summary. The job fails only if the scan itself fails. |
| `gate` | Waits, reports, and fails the job when open findings reach `fail-on` (default `high`). |

A gate on a pull request:

```yaml
on:
  pull_request:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: zksecurity/zkao-action@v1
        with:
          token: ${{ secrets.ZKAO_API_TOKEN }}
          project: ${{ vars.ZKAO_PROJECT_ID }}
          scan: diff
          mode: gate
          fail-on: high
```

## What to run

`scan` picks the kind of scan:

| `scan` | Runs |
| --- | --- |
| `quick-look` (default) | The core techniques in one cheap pass. |
| `deep-audit` | The full methodology over the whole repository. |
| `diff` | A quick look steered at the commits added since `base`. |
| any preset ref | That preset, for example `builtin:Deep Audit` or a custom one. |

A diff scan reads the change from GitHub (the pull request's base to its
head, or the commit before a push to the pushed commit) and hands the changed
files to the scan as guidance, on top of the repository's own guidance:
everything else is context, not a target. zkao does not yet have a scan that
reads only the diff, so this steers where the budget goes rather than
shrinking the scan. When that scan ships, `scan: diff` will run it.

## Inputs

| Input | Required | Default | What it does |
| --- | --- | --- | --- |
| `token` | yes | | Project API token. Use a secret. |
| `project` | yes | | The zkao project id. |
| `budget` | | recommended | Credit budget for the scan. Defaults to zkao's recommendation for this scan type on this repository. |
| `mode` | | `launch` | `launch`, `wait`, or `gate`. |
| `scan` | | `quick-look` | `quick-look`, `deep-audit`, `diff`, or a preset ref. |
| `base` | | see above | For `scan: diff`, the commit the change is measured from. |
| `fail-on` | | `high` | For `mode: gate`, the severity at which open findings fail the job: `critical`, `high`, `medium`, `low`, or `info`. |
| `repository` | | matched by name | The zkao repository id. By default the action finds the project repository whose owner and name match the workflow's repository. |
| `commit` | | see below | Commit to scan. |
| `branch` | | workflow branch | Branch the commit is on. Lets the scan reuse the branch's repository map. |
| `areas` | | whole repository | Comma-separated audit area keys to scope the scan to. |
| `guidance-file` | | | A file whose content replaces the repository's guidance for this scan. |
| `timeout` | | `10800` | Seconds to wait in `wait` and `gate` modes before giving up. The scan keeps running on zkao. |
| `summary` | | `true` | Write the scan link, and the findings once waited for, to the job summary. |
| `github-token` | | the workflow's | Reads the change for `scan: diff`. |
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
| `status` | `QUEUED` in `launch` mode; `COMPLETED`, `FAILED` or `CANCELLED` once waited for. |
| `findings-total` | Open findings: everything triage did not mark a false positive or a duplicate. Empty in `launch` mode. |
| `findings-critical`, `findings-high`, `findings-medium`, `findings-low`, `findings-info` | Open findings by severity. |

Use them in later steps:

```yaml
      - uses: zksecurity/zkao-action@v1
        id: zkao
        with:
          token: ${{ secrets.ZKAO_API_TOKEN }}
          project: ${{ vars.ZKAO_PROJECT_ID }}
          mode: wait
      - run: echo "${{ steps.zkao.outputs.findings-total }} open findings at ${{ steps.zkao.outputs.scan-url }}"
```

## Keeping the cost in check

A scan of the whole repository on every push adds up. Run on `pull_request`
or on `main` only, gate the job on the paths that matter, use `scan: diff`
for pull requests, or pass `areas` to scan the audit areas a change touches.
Area keys come from the repository's Context tab on zkao, or from
`zkao areas list`.

A scan of a repository zkao is still analyzing waits for that analysis to
finish first.

## How it works

The action is a composite step that runs the published
[`@zksecurity/zkao-cli`](https://www.npmjs.com/package/@zksecurity/zkao-cli)
against the public API. Nothing is compiled or vendored: the CLI version is
pinned in `action.yml` and can be overridden with `cli-version`. The runner
needs `node`, `jq` and `curl`, which every GitHub-hosted runner has.

## Releasing

Releases are GitHub releases with a semver tag (`v1.2.3`). Publishing one
re-points the major tag (`v1`) at it, so workflows pinned to `@v1` follow. Tick
"Publish this Action to the GitHub Marketplace" on the release form to update
the Marketplace listing.

## License

MIT, see [LICENSE](LICENSE).
