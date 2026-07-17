---
last_review_date: "2026-07-17"
---

# Homebrew/homebrew-cask Maintainer Guide

This guide is intended to help maintainers effectively maintain the cask repository. It is meant to be used in conjunction with the more generic [Maintainer Guidelines](Maintainer-Guidelines.md).

## Common Situations

Here is a list of the most common situations that arise in cask PRs and how to handle them:

- The `version` and `sha256` both change (keeping the same format): Merge.
- Only the `sha256` changes: Treat this as a retagged cask and follow the policy below.
- `livecheck` is updated: Use your best judgement and try to make sure that the changes follow the [`livecheck` guidelines](Brew-Livecheck.md).
- Only the `version` changes or the `version` format changes: Use your best judgement and merge if it seems correct (this is relatively rare).
- Other changes (including adding new casks): Use the [Cask Cookbook](Cask-Cookbook.md) to determine what's correct.

If in doubt, ask another cask maintainer on GitHub or Slack.

Unlike formulae, a cask's `sha256` stanza does not prove that an artefact is authentic because maintainers cannot realistically reproduce proprietary binaries.
It does reveal when a pinned download has changed.
Casks download from upstream; if a malicious actor compromised a URL, they could potentially compromise a version and make it look like an update.

## Retagged Casks

Some vendors replace an existing versioned download in place.
If the checksum changes without a corresponding version change, treat this as a potential upstream compromise or supply-side attack rather than a routine update.

Not all cask artefacts are code signed.
When an artefact is signed, a valid signature whose developer identity matches previous releases or the vendor's documented identity is a strong indicator that the changed download is legitimate.
Check and document the code-signing identity when available; an artefact is not suspicious merely because it is unsigned if previous releases were also unsigned.

Where possible, contact the vendor through an official contact page, public bug tracker or similar channel and ask them to confirm why the artefact changed and that it was not the result of a compromise.
Do not open or merge a PR updating the cask's checksum until the vendor has confirmed the change was intentional or it has been verified under the exception below.
The PR should link to the vendor's confirmation.

Use a lower verification bar for a proprietary cask whose vendor has no practical public contact channel.
In this case, direct confirmation is not required if the PR documents the code-signing result, when available, and the strongest other evidence, such as official release information.

## Deprecating, Disabling and Removing Casks

Do not deprecate, disable or remove a cask just because upstream asks us to or claims Homebrew's packaging is "broken". If our analytics show non-zero installs and our issue tracker is not receiving user reports that the cask is broken, keep it unless there is a clear enough technical, policy or project-wide reason to do otherwise.

When this happens, point upstream developers to [Working with Homebrew as an Upstream Project](Working-with-Homebrew-as-an-Upstream-Project.md) and keep the discussion in public on GitHub.

## Merging

In general, using GitHub's "Merge" button is the best way to merge a PR. This can be used when the PR modifies only one cask, regardless of the number of commits or whether the commit message format is correct. When merging using this method, the commit message can be modified if needed. Usually, version bump commit messages follow the form `Update CASK from OLD_VERSION to NEW_VERSION`.

If the PR modifies multiple casks, use the "Rebase and Merge" button to merge the PR. This will use the commit messages from the PR, so make sure that they are appropriate before merging. If needed, checkout the PR, squash/reword the commits and force-push back to the PR branch to ensure the proper commit format.

Finally, make sure to thank the contributor for submitting a PR!

## Other Tips

A maintainer can easily rebase a PR onto the latest default branch by adding a `/rebase` comment. `BrewTestBot` will automatically rebase the PR and add a reaction to the comment once the rebase is in progress and complete.
