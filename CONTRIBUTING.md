# Contributing

Ninja Paw is an independent community project maintained by Dr Bill Mcilhargey. It is educational and not affiliated with or endorsed by Microsoft Corporation. Microsoft product names and trademarks remain the property of Microsoft Corporation.

## Development

Use the Node.js version in `.node-version`, the npm version in `package.json`, Docker, Docker Compose, and Bash. Run the shared checks before opening a pull request:

```bash
npm ci
npm ci --prefix apps/pawton-manufacturing
npm test
bash scripts/test.sh --skip-azure
npm test --prefix apps/pawton-manufacturing
npm run build --prefix apps/pawton-manufacturing
```

The portal test command runs both `scripts/test-admin-portal.mjs` and `scripts/test-order-portal.mjs`; the deployment-assets workflow runs it on portal and test changes. For focused login and order regressions, run `node --test scripts/test-order-portal.mjs`.

Shared-login coverage includes both roles and legacy endpoints, role switching and cookie cleanup, cross-origin and malformed requests, credential/configuration boundaries, shared throttling and expiry, session tampering, and signing-key rotation. These tests use synthetic credentials and mocked SQL operations; they do not contact Azure or modify live orders. The form checks are source assertions, not browser tests. The root `npm run test:e2e` targets Scenario 1, not the Pawton portal; portal UI changes also need a local browser check of `/login`, both role redirects, and desktop/mobile layouts using test-only credentials.

Do not commit `.env` files, secrets, customer data, production credentials, generated Azure deployment output, or private infrastructure details.

The audit-template SQL integration test is opt-in and must run only against a disposable local SQL Server 2022 container. Set `DOJO_AUDIT_TEST_PORT` to its loopback-mapped SQL port and `MSSQL_SA_PASSWORD` to that container's test password, then run `node --test --test-name-pattern="reusable auditing SQL" scripts/test-admin-portal.mjs`. It creates a randomly named fixture database and audit definitions, uses the container's `/var/opt/mssql/log/` directory, verifies all scopes and no-overwrite behavior, and leaves artifacts for inspection. Remove the disposable container afterward and unset both variables. Do not point it at a persistent SQL instance; the test does not delete its fixtures. Without `DOJO_AUDIT_TEST_PORT`, normal portal tests skip this integration case.

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
