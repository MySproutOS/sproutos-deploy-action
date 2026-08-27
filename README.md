# Deploy to SproutOS

Upload a built application to SproutOS from GitHub Actions.

```yaml
permissions:
  contents: read
  id-token: write          # required — see below

steps:
  - uses: actions/checkout@v4
  - run: npm ci && npm run build
  - uses: MySproutOS/sproutos-deploy-action@v1
    with:
      preset: next
```

## You build; this uploads

Install and build steps are yours. SproutOS does not guess how your project is built, does not run
a build in a container you cannot see, and does not need a Dockerfile — GitHub already runs builds
well, and your workflow already knows how yours works.

What this action does is collect the output, upload it, and ask SproutOS to release it.
The release step waits for the platform to finish publishing. A migration or publication error
fails the workflow and prints the recorded failure reason and migrator output; the action never
retries a migration.

## Presets

| Preset | Default directory | What it is |
| --- | --- | --- |
| `next` | `.next/standalone` | Next.js with `output: "standalone"` |
| `hono` | `dist` | A bundled Hono server |
| `android` | `app/build/outputs/apk/release` | An unsigned APK — SproutOS signs it |
| `static` | `dist` | Files served from CDN |

Set `directory` to override.

**`next` needs `output: "standalone"` in `next.config`.** Without it `.next/standalone` does not
exist, and that is the most common way this action fails — so the error names the setting rather
than saying "not found".

**`android` uploads an unsigned APK.** SproutOS holds the signing key, because SproutOS is the
developer of record for every app it publishes. Your workflow never holds one.

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

Zip has no `--sort` and no way to omit timestamps, so the file list is sorted explicitly and every
entry's mtime is pinned before archiving. The same tree then produces the same bytes and the same
digest, and a redeploy of an unchanged build is visibly a no-op rather than looking like a new
artifact every time.
