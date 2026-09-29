# Fork notes

This is `maxmilneaus/tinycast`, a fork of [`abue-ammar/tinycast`](https://github.com/abue-ammar/tinycast).
Upstream's feature set is deliberately closed, so a local fork is the supported way to change it.

## The delta

One change on the `local/recency-sort` branch: **snippets are ordered by recency, not by name.**

Saving or expanding a snippet moves it to the front of the list. Uses are recorded in
`snippet-usage.json` beside the library in `~/Library/Application Support/<bundle-id>/` — never in the
Markdown, which stays a person's file. The full write-up is in
[docs/features/snippets.md](docs/features/snippets.md#order), which this fork edits in the same commit.

Upstream's answers on the two requests behind it: [#1015](https://github.com/abue-ammar/tinycast/issues/1015)
(recency grouping) and [#1027](https://github.com/abue-ammar/tinycast/issues/1027) (pin), both closed
`NOT_PLANNED`.

## Keeping up

```sh
git fetch upstream
git rebase upstream/main
git push --force-with-lease origin local/recency-sort
```

Conflicts land in `SnippetsStore.swift` or `SnippetsSettingsView.swift`, both of which upstream edits
often. `git config --global rerere.enabled true` makes a repeat of the same collision resolve itself.

## Building it

The `Tinycast Self-Signed` identity is required and created once — see
[docs/signing.md](docs/signing.md) §1. Then:

```sh
xcodegen generate        # only after adding or removing a source file
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
```

A debug build is its own channel — `Tinycast Dev.app`, bundle id `com.tinycast.app.dev` — so it runs
beside the Homebrew install with its own prefs, caches and Accessibility grant, and cannot clobber it.
Point **Settings → Snippets → Snippets Folder** at the same folder the installed app uses to keep one
library instead of two.

Do not build over `/Applications/Tinycast.app`: that path belongs to Homebrew and the app's own updater.
