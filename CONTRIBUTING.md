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

Use **Request release from dev** to select a patch, minor, major, or custom SemVer release. The workflow creates a release PR and synchronizes `package.json` and `package-lock.json`. Merging it into `main` allows **Publish main release** to validate metadata, create the version tag and GitHub Release, and publish versioned/latest container images.

## Legal and Trademark Notice

Microsoft, Azure, GitHub, Defender, and related marks belong to their respective owners. This project is not an approved or authorized Microsoft project and must not imply Microsoft sponsorship, endorsement, or ownership without written authorization.

Security reports belong in the private process described in [SECURITY.md](SECURITY.md).
