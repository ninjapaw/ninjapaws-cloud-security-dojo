# Deployment Plan

## Status
Validated

## Scope
Complete the Azure deployment lifecycle and close the infrastructure-as-code, CI, recovery, uninstall, and secret-handling gaps for the Ninja Paws Cloud Security Dojo.

## Decisions
- Keep GitHub OIDC bootstrap separate from routine deployment.
- Make `scripts/deploy.sh` support interactive setup, non-interactive deployment, and verification.
- Parameterize the container image name, image tag, and training settings in Bicep.
- Use an immutable image tag for deployment while retaining `latest` as a convenience tag.
- Preserve the existing Azure Container Registry, App Service, managed identity, and health-check architecture.
- Keep runtime deployment state non-secret and local under `.azure/`; never put OIDC bootstrap secrets in Key Vault or application settings.
- Use a separately protected manual workflow for destructive uninstall.

## Planned Changes
- Add staged `plan`, `doctor`, `provision`, `build`, `deploy`, `verify`, `repair`, and guarded `uninstall` commands.
- Persist resumable non-secret deployment metadata and tag owned resource groups.
- Route GitHub Actions infrastructure and application updates through the same staged script.
- Add a protected manual uninstall workflow.
- Add Bicep parameters and outputs needed by the deployment flow.
- Synchronize all checked-in ARM/Bicep templates and normalize OIDC environment values.
- Align `setup-azure-github-oidc.sh`, GitHub Actions, and README instructions.
- Add repository line-ending guidance for Bash scripts.
- Validate Bash syntax, Bicep syntax, and documentation/script consistency.

## Validation Proof
- `bash -n scripts/deploy.sh` passed.
- `bash -n scripts/setup-azure-github-oidc.sh` passed.
- `node` parsed `infra/main.json` and `azuredeploy.json` successfully.
- `git diff --check` passed.
- `scripts/deploy.sh plan --environment dev --image-tag test-tag` passed.
- ARM deploy-button template parameters now match the Bicep training settings.
- Azure CLI 2.89.1 and Bicep 0.46.1 installed successfully.
- `az bicep build` passed for `infra/main.bicep` and `infra/parameters.bicep`.
- `scripts/deploy.sh doctor --environment prod` passed with Azure authentication.
- Local deployment now detects `dev` -> `dev` and `main` -> `prod` from the current Git branch.
- GitHub Actions now derives its GitHub Environment exclusively from `github.ref_name`.
- Added a manual `dev`-only promotion workflow that opens or reuses a `dev` -> `main` pull request without merging it.
- Documented required `main` branch checks and `prod` Environment reviewers for promotion.
- Environment variables now hold non-secret per-environment deployment configuration; runtime secrets are reserved for Key Vault references when introduced.
- Added interactive/default configuration modes and uninstall cleanup for repository-managed GitHub Environment variables.
- Documented organization-variable sharing guidance and the boundary that uninstall must not delete organization-owned variables.
- Final review passed for branch routing, staged lifecycle, OIDC bootstrap, GitHub variable ownership, promotion, uninstall, and validation workflows.
- Authenticated `doctor` passed for both `dev` and `prod`; Azure what-if remained non-destructive.
- Added portable `scripts/test.sh` coverage for Bash syntax, branch routing, ARM JSON, and Bicep compilation.
- `bash scripts/test.sh --skip-azure` passed under the current Bash environment.
- Full `bash scripts/test.sh` passed with Azure CLI/Bicep enabled.
- Deployment wrappers now check `tr`, support Windows Node discovery, and translate WSL paths for Windows Azure CLI.
- Azure what-if preview: 4 resources to create and 2 resources to update in `NP-ninjapaws-dojo-CentralUS`.
- No Azure deployment or destructive operation was executed during validation.
