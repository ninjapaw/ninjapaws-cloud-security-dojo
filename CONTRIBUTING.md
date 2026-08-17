docker build -t ninjapaws-dojo:test .
docker-compose up -d
curl http://localhost:8080/health
docker-compose logs -f
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

Recommended PR content:

- a brief summary of the change
- why the change is needed
- how it was validated
- any follow-up actions or dependencies

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

## Legal note

This project is an independent community project and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation. Microsoft trademarks and product names remain the property of Microsoft Corporation.

## Code of conduct

Contributions should be respectful, constructive, and educational. Please do not use the repository to promote unsafe or harmful behavior.

## License

By contributing to this project, you agree that your contributions will be licensed under the terms of the [MIT License](LICENSE).
- Read through workflows in `.github/workflows`
- Ask questions in issues with `question` label

## 🙏 Thank You!

Your contributions help make cloud security education better for everyone. Thank you for being part of the Ninja Paws community!

---

**Ready to contribute? Let's make security training amazing together! 🥷🛡🐾**
