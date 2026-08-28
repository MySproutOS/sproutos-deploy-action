# Deploy to SproutOS

Upload a built application to SproutOS from GitHub Actions.

```yaml
permissions:
  contents: read
  id-token: write          # required — see below

steps:
  - uses: actions/checkout@v5
  - run: npm ci && npm run build
  - uses: MySproutOS/sproutos-deploy-action@v1
    with:
      preset: next
```

## You build; this uploads

Install and build steps are yours. SproutOS does not guess how your project is built, does not run
a build in a container you cannot see, and does not need a Dockerfile — GitHub already runs builds
well, and your workflow already knows how yours works.

What this action does is install one pinned, checksummed and provenance-verified release of the
`sprout` CLI, then ask that CLI to collect the output, upload it, and release it. The Action and a
local `sprout deploy` therefore use the same packager and request contract instead of two shell and
Rust implementations that can drift apart.
The release step waits for the platform to finish publishing. A migration or publication error
fails the workflow and prints the recorded failure reason and migrator output; the action never
retries a migration.

## Presets

| Preset | Default directory | What it is |
| --- | --- | --- |
| `next` | `.next/standalone` | Next.js with `output: "standalone"` |
| `hono` | `dist` | A bundled Hono server |
| `web` | `.sproutos/dist` | A generic executable bundle with its own `run.sh` |
| `android` | `app/build/outputs/apk/release` | An unsigned APK — SproutOS signs it |
| `static` | `dist` | Files served from CDN |

Set `directory` to override.

**`next` needs `output: "standalone"` in `next.config`.** Without it `.next/standalone` does not
exist, and that is the most common way this action fails — so the error names the setting rather
than saying "not found".

**`web` is runtime-neutral.** It does not add a Node entrypoint and is not an alias for Hono. For
example, a static Go arm64 bundle can set `runtime: provided.al2023` and `handler: run.sh` while the
directory contains its executable and executable `run.sh`.

**`android` uploads the original unsigned APK bytes.** It is not put in a zip. SproutOS holds the
per-app signing key, because SproutOS is the developer of record for every app it publishes. Your
workflow never holds one. The Action reads `versionCode` from Gradle's `output-metadata.json`; set
`version-code` when passing a direct APK or non-Gradle output.

## One pinned, verified CLI

The Action never downloads `latest`. Its source pins an exact CLI version, checks the selected
platform asset against both the release manifest and `SHA256SUMS`, and verifies GitHub's artifact
attestation against `MySproutOS/SproutOS` before executing it. An old runner without attestation
support fails closed. Updating the CLI is an ordinary reviewed Action commit, so the same Action
revision always runs the same deployment implementation.

## Authentication is a token nobody stores

`id-token: write` lets GitHub mint a short-lived OIDC token for this run, which SproutOS exchanges
for a deploy token. Nothing is stored in your repository.

A long-lived deploy secret is a credential that outlives whoever added it, leaks through a fork's
pull-request workflow, and has to be rotated by hand. The OIDC token expires in minutes and carries
claims SproutOS verifies — repository, ref, workflow — so a token minted in somebody else's
repository cannot deploy your project.

A workflow grants its own permissions and an action cannot request them on its behalf, so if
`id-token: write` is missing the action fails with the four lines you need to add.

## Which project, when a repository holds several

A repository can hold more than one SproutOS project — a monorepo deploying a web app and an API
separately, or projects grouped under the repository they were built from. Say which one a workflow
deploys:

```yaml
- uses: MySproutOS/sproutos-deploy-action@v1
  with:
    preset: hono
    directory: apps/internal-api
    project: reddit-clone-api
```

Leaving it unset is fine for a repository with exactly one project. With more than one the deploy is
**refused**, and the error lists the candidates. That is deliberate: guessing would deploy the right
code onto the wrong service, which is indistinguishable from success until somebody notices the API
has been serving the website for a week.

Naming a project *group* is refused too, and says so — a group holds other projects and deploys
nothing itself.

## Migrations

Point `migration-directory` at a built migrator and it runs **before** the new version takes
traffic:

```yaml
    migration-directory: apps/dbmigrator/build
    migration-handler: migrate.handler
```

A failed migration fails the deploy and leaves the previous release serving. It is never retried
automatically — re-running a partially applied schema change is how a recoverable failure becomes an
unrecoverable one — and Lambda's 15-minute ceiling is the hard timeout.

Unset means this project has no migration step, which is recorded as `skipped` rather than as
nothing: "no migrations" and "somebody forgot" should not look the same.

## Static assets go to a platform bucket, not your object storage

`static-paths` publishes build output to a **platform-managed** bucket served through the CDN. It is
shared across tenants and keyed by project, and the key prefix is the tenancy boundary.

It is **not** the `object_storage` service you provision. That one is yours, has its own
credentials, and is where files your application uploads at runtime belong. Nothing in this action
writes to it.

## Size

Archives over 200 MB are refused, with the size in the message. AWS Lambda's limit is 250 MB
unzipped including layers, and a standalone Next.js tree with `sharp` gets close — better to be told
here than by AWS several minutes later, in a message about a deployment package.

## Reproducible archives

The output is a **zip**, because that is what Lambda reads. Every preset uses the same format —
`unzip` is as available as `tar` on any machine that needs one, and two archive formats is one more
than the platform has a reason for.

The pinned `sprout-core` packager sorts paths, normalizes archive metadata without changing the
source tree, preserves safe symlinks, and verifies every digest at the upload boundary. The same
tree produces the same bytes and digest from the Action and from local `sprout deploy`. Android is
the exception by design: its already-built APK is uploaded byte-for-byte and its SHA-256 is over
those raw bytes.
