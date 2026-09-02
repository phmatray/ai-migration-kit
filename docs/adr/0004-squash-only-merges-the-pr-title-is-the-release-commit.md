---
id: 4
title: 'Squash-only merges: the PR title is the release commit'
status: accepted
date: 2026-08-31
tags:
- release
- merge-pr
code_refs:
- path: release-please-config.json
- path: scripts/release-title-gate.sh
parent: Architectural Decision Records
nav_order: 4
---

# Squash-only merges: the PR title is the release commit

## Context and Problem Statement

Consumers install a version-keyed cache of this plugin — a whole-repo checkout of the tagged commit —
so a fix to anything they run only reaches them once a release is cut here. This repo squash-merges,
which makes the pull request *title*, not any commit on the branch, the message release-please reads
on `main`. (Context lifted from the `$comment` key in `release-please-config.json`; #27, widened by
#55.)

## Considered Options

- Merge commits, and let release-please read the individual commit subjects.
- Squash merges, with the PR title gated for a releasable Conventional Commits type.
- Squash merges with no gate, relying on review to catch an unreleasable title.

## Decision Outcome

`main` is linear and squash-only — `allow_merge_commit` and `allow_rebase_merge` are both false
server-side — and `scripts/release-title-gate.sh` fails any PR that touches shipped plugin content
without a releasable title, defining "shipped" by exclusion from a `NON_SHIPPED` list rather than by
enumeration, with a carve-out for release-please's own `chore(main): release X.Y.Z` PR so a release
can still merge.

## Consequences

Change the merge strategy, or that script's releasable set, and the delivery guarantee has to be
re-established somewhere else. The gate only sees the `pull_request` event, so two holes stay open by
construction: overriding the squash subject at merge time, and a direct push to `main`.
