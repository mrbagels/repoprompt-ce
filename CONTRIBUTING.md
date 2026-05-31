# Contributing to RepoPrompt CE

RepoPrompt CE is a community repository. The contribution gate keeps incoming
work manageable and gives maintainers room to review changes carefully.

## Contribution Gate

The initial approved-contributor list is made up of RepoPrompt customers who
submitted a GitHub username through the claim form and matched an eligible
customer record.

New issues and pull requests from accounts that are not approved are closed
automatically. Maintainers may reopen worthwhile issues after review.

The gate uses [`.github/APPROVED_CONTRIBUTORS`](.github/APPROVED_CONTRIBUTORS).
Each entry has one capability:

- `issue`: issues stay open.
- `pr`: issues and pull requests stay open.

Approved contributors may open a pull request to propose additions or removals.
Core contributors decide whether to merge those changes.

The allowlist does not grant repository access. Invitations and organization
membership are managed separately.

## Before Submitting A Pull Request

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Do not check raw generated RP outputs into the repo; prompts, reviews,
investigations, analysis, designs, and reference dumps are working artifacts
unless deliberately distilled into durable docs.

Run the smallest relevant coordinated validation commands from [`AGENTS.md`](AGENTS.md).
At minimum:

```bash
make guardrails
make dev-lint
```

Add focused `make dev-test FILTER=<SuiteName>` coverage for behavior changes.

Do not change release metadata, signing identities, bundle IDs, Sparkle keys, or
release channels unless a maintainer has explicitly requested it.
