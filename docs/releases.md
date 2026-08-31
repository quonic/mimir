# Releases

Mimir is released from git tags. Two workflows do the work:

- `.github/workflows/ci.yml` runs `odin check .`, `odin test .`, and a build on
  every push to `main` and every pull request.
- `.github/workflows/release.yml` runs on tags that match `v*` and publishes a
  GitHub release.

## Cutting a release

1. Merge the changes into `main`.
2. Tag the commit on `main` and push the tag:

   ```sh
   git checkout main
   git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

Tags use the form `vMAJOR.MINOR.PATCH`. A tag with a suffix, such as
`v0.2.0-rc1`, is published as a pre-release and does not become the latest
release.

The tagged commit must be on `main`. GitHub cannot filter tag triggers by
branch, so the `guard` job checks the ancestry and fails the workflow if the tag
points somewhere else.

## Assets

Each release carries:

| Asset                            | Contents                            |
| -------------------------------- | ----------------------------------- |
| `mimir-<tag>-linux-amd64.tar.gz` | `mimir`, `README.md`, `LICENSE`     |
| `mimir-<tag>-windows-amd64.zip`  | `mimir.exe`, `README.md`, `LICENSE` |
| `SHA256SUMS`                     | SHA-256 checksum of every archive   |

Windows Terminal is the preferred way to run `mimir.exe`; plain `cmd.exe`
(conhost) is supported best-effort.

## Verifying a download

Check the checksum:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

Check the build provenance, which proves the archive came from this repository's
release workflow:

```sh
gh attestation verify mimir-v0.2.0-linux-amd64.tar.gz --repo quonic/mimir
```

## Release immutability

The workflow creates the release as a draft, attaches every asset, and only then
publishes it. GitHub freezes assets when a release is published, so nothing may
be uploaded afterwards. If a release is wrong, tag a new version instead of
editing the old one.

Immutable releases are enabled in the repository settings.
