# Changelog

All notable changes to the Kubuno Docker distribution are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this repository follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The image builds with the speech-to-text module in it.** Adding that module
  to the image surfaced a build dependency the image lacked: the module
  generates its bindings with a tool that loads `libclang` at build time, which
  the hosted runners provide but this image did not. The failure could only ever
  appear here, never in the module's own build.
- **A module without a user interface no longer breaks the image.** The
  assembly script assumed every module ships one and stopped on the first
  that does not. Speech-to-text has no screen, which is legitimate, so the
  interface step is now skipped for such a module instead of failing.


### Fixed

- **The published image now really contains every module it advertises.** The
  all-in-one image built and pushed for a release was missing `stt`: it shipped
  21 modules while the manifest and the Dockerfile both announced 22. The module
  list existed in three places, and the one the build actually used — a copy
  hardcoded in the release workflow — had not been updated. The workflow now
  derives the list from `VERSIONS`, the manifest that already records which tag
  of each component the image contains, so a component pinned there can no
  longer be left out of the image that claims to ship it.


### Changed

- **The README now opens with the Kubuno logo.** The public README on GitHub
  shows the Kubuno crest at the top of the page. The image ships in-repo, under
  `.github/logo.svg`, so it renders even when the repo is browsed offline.


### Security

- **The Compose deployment no longer ships a default administrator password.**
  `KUBUNO_ADMIN_PASSWORD` fell back to `kubuno` when unset — a password written
  in a public repository, and therefore known to anyone who could reach the port
  before the owner did. It also quietly cancelled the server's own rule: given no
  password, the server draws a random one, writes it to
  `/var/lib/kubuno/initial-admin-password` (readable by the service account
  alone) and demands a change at first login. Because the fallback always
  supplied a value, that rule could never apply to a Docker install. The
  variable now defaults to empty, which the server reads as "not set", so a
  Docker deployment behaves like every other one. The public demo is unaffected:
  it sets the password explicitly.
