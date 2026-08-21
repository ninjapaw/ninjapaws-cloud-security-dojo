# Contributing

Ninja Paw is an independent community project maintained by Dr Bill Mcilhargey. It is educational and not affiliated with or endorsed by Microsoft Corporation. Microsoft product names and trademarks remain the property of Microsoft Corporation.

## Development

Use Node.js 20+, Docker, Docker Compose, and Bash. Run the shared checks before opening a pull request:

```bash
npm ci
npm test
bash scripts/test.sh --skip-azure
```

Do not commit `.env` files, secrets, customer data, production credentials, generated Azure deployment output, or private infrastructure details.

## Branch Flow

- Feature branches merge into `dev`.
- `dev` is the development deployment environment.
- Use **Promote dev to main** to create the promotion pull request.
- `main` is production and must remain protected.
- Production deployment occurs after the reviewed promotion PR merges.

## Pull Requests

Include:

- What changed and why
- Validation commands and results
- Security or infrastructure impact
- Configuration or GitHub Environment variable changes
- Rollback or follow-up considerations

Required checks depend on the change and may include infrastructure validation, remediation validation, package metadata checks, and deployment verification. Do not bypass branch protection or environment approvals.

## Releases

Use **Request release from dev** to select `auto`, `patch`, `minor`, `major`, or `custom`. `auto` (the default) runs `scripts/determine-version-bump.sh`, which classifies the commits since the last release using a Conventional Commits heuristic and, when available, GitHub Models - the AI result can only escalate the bump (e.g. heuristic `patch` -> AI `minor`), never downgrade it, so the workflow always has a safe deterministic fallback. The workflow creates a release PR that synchronizes `package.json`, `package-lock.json`, and `config/shared.config.json`'s `configVersion` to the same version. Merging it into `main` allows **Publish main release** to validate metadata (including that `configVersion` still matches `package.json`), create the version tag, publish the GitHub Release marked `latest`, and publish versioned/`latest` container images.

Use **Publish dev prerelease** from `dev` at any time to preview the next version without touching `package.json`. It runs the same bump determination, tags a `vX.Y.Z-dev.<run>` prerelease, and publishes a GitHub prerelease that is explicitly never marked `latest`.

## Legal and Trademark Notice

Microsoft, Azure, GitHub, Defender, and related marks belong to their respective owners. This project is not an approved or authorized Microsoft project and must not imply Microsoft sponsorship, endorsement, or ownership without written authorization.

Security reports belong in the private process described in [SECURITY.md](SECURITY.md).
