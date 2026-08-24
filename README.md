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

## Size

Archives over 200 MB are refused, with the size in the message. AWS Lambda's limit is 250 MB
unzipped including layers, and a standalone Next.js tree with `sharp` gets close — better to be told
here than by AWS several minutes later, in a message about a deployment package.

## Reproducible archives

`tar` runs with a fixed mtime and sorted names, so the same tree produces the same bytes and the
same digest. A redeploy of an unchanged build is then visibly a no-op, rather than looking like a
new artifact every time.
