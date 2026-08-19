# Contributing to Ninja Paws Cloud Security Dojo

Thank you for contributing to the Ninja Paws Cloud Security Dojo. This project is designed for defensive security training, learning, and demonstration.

## Contributing guidance

We welcome thoughtful contributions that improve the training value, clarity, or security guidance in this project.

When contributing, please keep changes focused, actionable, and aligned with the educational purpose of the repository.

## Reporting issues

Before opening an issue or pull request, please:

1. Check whether the issue already exists.
2. Include a clear title and summary.
3. Provide reproducible steps when applicable.
4. Mention any environment or configuration details.

## Pull request expectations

Please keep pull requests narrow and clear.

Every pull request should include:

- a concise summary and reason for the change
- validation performed, including relevant commands or workflow runs
- security impact, if the change affects dependencies, containers, infrastructure, or identity
- follow-up work or deployment considerations

For remediation exercises, state the affected CVE, the previous and patched dependency versions, and evidence that the runtime reports the expected remediation state.

## Local validation

```bash
npm ci
npm start
curl http://localhost:3000/health

./scripts/compose.sh up --build -d
curl http://localhost:8080/health
./scripts/compose.sh down
```

Use [config/deployment.json](config/deployment.json) for non-secret local configuration. Never add credentials, generated Azure output, or `.env` files to the repository.

## Security and safe use

This repository is intentionally educational and should not be used for offensive or harmful activity.

Contributors must avoid adding:

- production secrets or credentials
- customer or business-sensitive data
- exploitation code or weaponized examples
- unauthorized or unsafe deployment guidance

## Documentation standards

Please keep documentation accurate, concise, and easy to follow for learners.

Use simple examples, clear steps, and safe, placeholder values when describing environment settings.

## Code of conduct

Contributions should be respectful, constructive, and educational. Please do not use the repository to promote unsafe or harmful behavior.

## Legal and license

This project is an independent community project and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation. Microsoft trademarks and product names remain the property of Microsoft Corporation.

By contributing to this project, you agree that your contributions will be licensed under the terms of the [MIT License](LICENSE).
