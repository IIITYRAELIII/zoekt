# Native Windows support

This fork restores native Windows builds for the indexer, command-line search,
and web server. Windows shard files use `CreateFileMapping` and
`MapViewOfFile`, providing the same zero-copy read model as Unix `mmap`.

No extra mmap dependency is used: the implementation relies on the existing
`golang.org/x/sys/windows` module.

## Build

Use Go 1.25.9 or newer:

```powershell
go build ./cmd/zoekt-index
go build ./cmd/zoekt
go build ./cmd/zoekt-webserver
```

Run the end-to-end native smoke test:

```powershell
./contrib/windows/Smoke-Test.ps1
```

The smoke test builds all three commands, indexes a small UTF-8 corpus with
Cyrillic BSL filenames and content, searches it through the CLI, starts the
official web server, repeats the search through HTTP, rebuilds the index while
the server still has the old shard mapped, and verifies that the server
observes the new content. It creates and removes only a uniquely named
directory under the system temporary directory.

To compare an existing BSL index with ripgrep on the same source corpus:

```powershell
./contrib/windows/Measure-BslSearch.ps1 `
  -Source C:\path\to\bsl-source `
  -Index C:\path\to\zoekt-index `
  -Zoekt C:\path\to\zoekt.exe
```

The benchmark performs a warm-up, verifies equal match counts for three
dynamic-list queries, and returns median timings as JSON. Paths are supplied
at runtime and are not stored in the repository.

## Automated validation

The Windows CI job covers:

- query and search package tests;
- the Windows memory-mapped `IndexFile`;
- Windows disk-space handling in `zoekt-webserver`;
- native index, CLI search, and web-server search with UTF-8 BSL.

The existing Linux CI remains enabled. The Linux `/proc` mmap metrics from
upstream are retained in a Linux-only source file; non-Linux systems use the
existing no-op collector.

Windows support in this fork is currently scoped to `zoekt-index`, the
`zoekt` CLI, and `zoekt-webserver`. Several upstream mirroring and
Sourcegraph-specific commands still assume POSIX shells, Unix signals, and
slash-only golden paths; they are not declared Windows-compatible by this
fork. The Windows CI therefore tests the supported commands and portable
search packages instead of presenting the Unix-oriented `go test ./...` suite
as a valid Windows gate.

## Provenance

This implementation combines and validates ideas from:

- Sourcegraph PR
  [#941](https://github.com/sourcegraph/zoekt/pull/941), which split
  web-server and index-builder behavior by platform but used allocated
  `ReadAt` calls for Windows and did not include a real Windows run;
- Embark Studios PR
  [#1012](https://github.com/sourcegraph/zoekt/pull/1012), which restored mmap
  through `mmap-go` but was closed without CI or runtime evidence;
- an independent native Windows experiment on upstream commit
  `2b2ce2e398e6bee68d67143f567b6c6199340c7f`, using
  `golang.org/x/sys/windows` and validated against a large BSL corpus.

## ERP/BSL validation

The large validation corpus is an exported ERP-class 1C configuration. Its
source is proprietary and is not included in this repository; only aggregate
measurements are published.

- 29,694 `.bsl` files;
- 1,659,624,425 source bytes (1.546 GiB);
- 16 index shards;
- 3,288,904,830 index bytes (3.063 GiB);
- 339.7 seconds to build the index;
- 792.4 MiB observed peak working set while indexing.

Zoekt and ripgrep returned identical counts and source positions for three
control searches:

- exact `ОписаниеТипов("ДинамическийСписок")`: 10 matches;
- all `ДинамическийСписок` lines: 959 matches;
- programmatic form-attribute regular expression: 8 matches.

Across seven warm command-line runs, Zoekt completed the three searches in
117–119 ms median time. Ripgrep required 2,314–2,387 ms on the same corpus,
making indexed search approximately 20 times faster for these cases.

A persistent search process answered 100 repetitions of each query in
0.341–1.834 ms median time with p95 of 0.566–3.111 ms. After the measured
load it used approximately 311 MiB of working memory.

After integrating the complete Windows platform layer, the fork binary was
run against the retained 3.063 GiB index again. The three control counts
remained 10, 959, and 8 and matched ripgrep. The official
`zoekt-webserver` opened the full index successfully, returned the expected
Cyrillic result over HTTP, used approximately 304 MiB of working memory, and
answered the second HTTP request in 3.2 ms.

These figures describe one Windows machine and one corpus, not a general
performance guarantee. The committed smoke test is the reproducible public
correctness check; the proprietary corpus remains an external regression
test.
