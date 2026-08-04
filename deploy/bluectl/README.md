# bluectl release configs

This directory holds the bluectl config folders used by the
`rune-language-zig` release pipeline.

Layout (one config per env × OS × arch):

```
deploy/bluectl/
  prod/
    darwin-arm64/config
    darwin-amd64/config
    linux-arm64/config
    linux-amd64/config
  staging/
    darwin-arm64/config
    darwin-amd64/config
    linux-arm64/config
    linux-amd64/config
```

- `prod/*/config`    pin `auth.project-id: rune-prod`
- `staging/*/config` pin `auth.project-id: unstable-build-blue-dev`
- `release.collection` / `release.bucket` are set per-OS/arch to
  `rune-release-<os>-<arch>` so uploads land in the right bucket.

Credentials are NOT committed here: bluectl falls back to the
developer's gcloud Application Default Credentials.

## Safety property

The `dist-<env>-<os>-<arch>` make targets pass
`-c deploy/bluectl/<env>/<os>-<arch>` to bluectl, so the publishing
project-id and bucket are selected by the make target rather than by
whatever happens to be in `~/.bluectl/config`. This makes it impossible
for a developer's ambient `~/.bluectl/config` to silently redirect a
release upload to the wrong environment or wrong bucket.

If you need to add credentials or other auth fields, do it via your
personal `~/.bluectl/config` or the environment, never in this
directory.