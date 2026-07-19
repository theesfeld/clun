# Changelog

All notable changes to Clun are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Clun is pre-1.0; minor versions may include breaking changes.

The immutable tags `v0.1.0-dev.2`, `v0.1.0-dev.11`, `v0.1.0-dev.12`,
`v0.1.0-dev.15`, `v0.1.0-dev.68`, and
`v0.1.0-dev.69` did not produce GitHub Releases or assets and are not
installable release checkpoints.

## [Unreleased]

## [0.1.0-dev.70] - 2026-07-19

### Added

- Add a root Keep a Changelog record covering every published checkpoint.
- Include the built-in `--update`, `update`, and non-mutating `check-update`
  surfaces staged by the tag-only dev.69 candidate.

### Changed

- Carry the Phase 82 candidate forward from immutable, tag-only
  `v0.1.0-dev.69` into a new recovery slot without moving or reusing a tag.
- Preserve `v0.1.0-dev.21` as the installer default until dev.70 assets are
  published and verified.
- Correct public capability claims to the evidence-backed 28 Yes / 2 Partial /
  0 No snapshot and enforce complete canonical Issue labels.

### Fixed

- Resolve workspace-link endpoints canonically so relative package links remain
  valid through Darwin's `/tmp` to `/private/tmp` alias.
- Make CookieMap scaling evidence deterministic with rotated paired trials and
  median ratios while retaining the strict `< 3.25` timing bound and allocation
  checks.
- Make blocking HTTPS frame-aware so complete Content-Length and chunked bodies
  finish without waiting for EOF, while truncated and until-close bodies still
  fail closed without authenticated `close_notify`.

### Security

- Remove the image-provided untrusted `aws/tap` before Homebrew dependency
  resolution on Darwin compatibility and release runners.

## [0.1.0-dev.21] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.21)

### Added

- Ship the Phase 37 modern ECMAScript gap-wave checkpoint.

## [0.1.0-dev.19] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.19)

### Added

- Ship the Phase 66 Jest-compatible test-runner checkpoint.

## [0.1.0-dev.18] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.18)

### Added

- Ship the Phase 65 cross-platform shell API checkpoint.

## [0.1.0-dev.17] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.17)

### Added

- Ship the Phase 50 router, static-file, and FileSystemRouter checkpoint.

## [0.1.0-dev.16] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.16)

### Fixed

- Recover the Phase 31 YAML API and module-loading release after the tag-only
  dev.15 attempt.

## [0.1.0-dev.14] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.14)

### Added

- Ship the Phase 36 password and hashing API checkpoint.

## [0.1.0-dev.13] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.13)

### Added

- Ship the Phase 34 CSS Color API checkpoint.

### Fixed

- Recover the Glob and CookieMap release path from earlier tag-only attempts.

## [0.1.0-dev.10] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.10)

### Added

- Ship the Phase 33 terminal string-width and ANSI-utility checkpoint.

## [0.1.0-dev.9] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.9)

### Added

- Ship the Phase 35 CSRF API checkpoint.

## [0.1.0-dev.8] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.8)

### Added

- Ship the Phase 29 public SemVer API checkpoint.

## [0.1.0-dev.7] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.7)

### Added

- Ship the Phase 27 compatibility ledger and release-document automation.

## [0.1.0-dev.6] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.6)

### Added

- Ship async generators and async iteration.

## [0.1.0-dev.5] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.5)

### Added

- Ship synchronous generators and delegation semantics.

## [0.1.0-dev.4] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.4)

### Added

- Ship the function and class conformance checkpoint.

## [0.1.0-dev.3] - 2026-07-15

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.3)

### Added

- Ship iterator and binding semantics.

### Fixed

- Recover release teardown after the tag-only dev.2 attempt.

## [0.1.0-dev.1] - 2026-07-15

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.1)

### Added

- Ship the first Phase 25b Object and compile-tier development checkpoint.

## [0.0.1-dev] - 2026-07-14

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.0.1-dev)

### Added

- Publish the initial Clun development release.

[Unreleased]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.70...HEAD
[0.1.0-dev.70]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.21...v0.1.0-dev.70
[0.1.0-dev.21]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.19...v0.1.0-dev.21
[0.1.0-dev.19]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.18...v0.1.0-dev.19
[0.1.0-dev.18]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.17...v0.1.0-dev.18
[0.1.0-dev.17]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.16...v0.1.0-dev.17
[0.1.0-dev.16]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.14...v0.1.0-dev.16
[0.1.0-dev.14]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.13...v0.1.0-dev.14
[0.1.0-dev.13]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.10...v0.1.0-dev.13
[0.1.0-dev.10]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.9...v0.1.0-dev.10
[0.1.0-dev.9]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.8...v0.1.0-dev.9
[0.1.0-dev.8]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.7...v0.1.0-dev.8
[0.1.0-dev.7]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.6...v0.1.0-dev.7
[0.1.0-dev.6]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.5...v0.1.0-dev.6
[0.1.0-dev.5]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.4...v0.1.0-dev.5
[0.1.0-dev.4]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.3...v0.1.0-dev.4
[0.1.0-dev.3]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.1...v0.1.0-dev.3
[0.1.0-dev.1]: https://github.com/theesfeld/clun/compare/v0.0.1-dev...v0.1.0-dev.1
[0.0.1-dev]: https://github.com/theesfeld/clun/releases/tag/v0.0.1-dev
