echo "SECRETS GO HERE" > .env.local
git add .gitignore  # Ensure .env.local is ignored
## Security

This project is an educational cloud security training environment. It is intended to demonstrate defensive security practices, vulnerability detection, and remediation in a safe and controlled way.

This repository is not a Microsoft product and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation.

## Reporting security issues

Please do not open a public GitHub issue for security vulnerabilities.

Instead, use the repository's private security reporting process or the appropriate maintainer contact for the project. If you are reporting an issue, include:

- type of issue
- affected files or components
- reproduction steps or environment details
- potential impact
- suggested remediation, if known

If the issue is a general project concern rather than a security issue, open a normal GitHub issue with the details needed to understand and reproduce it.

## Security expectations

This repository intentionally demonstrates defensive security workflows and should be used only in safe, non-production, authorized environments.

The training environment contains example and placeholder values only. It does not include customer data, production credentials, or business-sensitive information.

This project is for educational purposes only and does not teach exploitation, malicious tradecraft, or offensive security techniques.

## Best practices used in this project

- GitHub security scanning and dependency review
- Container image scanning with Microsoft Defender for Cloud and vulnerability reporting
- Azure security baselines and managed identity guidance
- Principle of least privilege and RBAC examples
- Clear separation between training content and production systems

## Trademark and legal note

Microsoft trademarks and product names are the property of Microsoft Corporation. Use of Microsoft names, logos, or trademarks must comply with Microsoft's trademark and branding guidance and must not imply endorsement or sponsorship.

## Policy

This repository follows a responsible and transparent approach to vulnerability disclosure and public learning content. Security reports should be handled privately and with the expectation that issues will be reviewed responsibly and remediated in line with the educational purpose of the project.

## License

The project is licensed under the [MIT License](LICENSE).
