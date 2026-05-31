# RepoPrompt CE

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-black)

**The open-source macOS Context IDE for AI coding agents.**

RepoPrompt CE helps you assemble, inspect, and hand off rich codebase context:
pick the right files, summarize project structure and Git history, and package
it all into a dense, reviewable prompt for ChatGPT, Claude, Codex, Cursor, and
other AI coding tools. You can also hand that context straight to agents through
the bundled MCP server and CLI.

## What You Can Do

- Curate focused, reviewable context for an AI model from one or more
  repositories.
- Combine selected files, project-structure maps, function/type CodeMaps, and
  Git diffs in a single prompt.
- Run Context Builder to discover relevant code and produce an optimized prompt.
- Plan, review, and ask follow-up questions in built-in chat, including an
  Oracle flow for second opinions.
- Run longer agent sessions in Agent Mode with supported CLI-backed providers.
- Connect external MCP clients to search, inspect, and select repository context
  from your own tools.

## Project Status

RepoPrompt CE is the open-source community edition of RepoPrompt, originally a
paid macOS app. It removes paid activation flows and license keys while keeping
the core prompt, copy, chat, CodeMap, Agent Mode, and custom-provider features
available without paid license gates. The project is licensed under
[Apache-2.0](LICENSE).

Maintainers track release signing, Sparkle metadata, dependency pins, and
third-party notices in [`docs/open-source-readiness.md`](docs/open-source-readiness.md).

## User Guide

RepoPrompt CE currently runs as a local source build. You need macOS 14 or
later and Xcode 26 or matching Command Line Tools with the macOS 26 SDK. You do
not need to open Xcode.

To run the app, double-click
[`Launch RepoPrompt CE.command`](Launch%20RepoPrompt%20CE.command) in Finder.
The launcher builds and opens RepoPrompt CE for you.

Keep the small launcher terminal open while you use the app:

- `r` rebuilds and relaunches.
- `s` shows app status.
- `x` stops the app.
- `q` closes the launcher without stopping the app.

## Contributor And Agent Docs

The detailed development workflow lives in focused docs:

- [`AGENTS.md`](AGENTS.md): start here for coordinated builds, tests, launches,
  live MCP checks, source placement, and contribution preflight.
- [`CONTRIBUTING.md`](CONTRIBUTING.md): contribution policy and pull request
  steps.
- [`docs/architecture/source-layout.md`](docs/architecture/source-layout.md):
  source ownership and placement rules.
- [`docs/architecture/provider-plugins.md`](docs/architecture/provider-plugins.md):
  Agent Mode provider architecture.
- [`docs/releasing.md`](docs/releasing.md): release-candidate and publishing
  workflows.
- [`docs/open-source-readiness.md`](docs/open-source-readiness.md): public
  readiness inventory.
