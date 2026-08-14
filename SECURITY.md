## Security Policy

This document outlines security practices for the Ninja Paws Cloud Security Dojo project.

### Purpose

This is an **educational project** designed to teach cloud security concepts through hands-on demonstration of vulnerability detection and remediation.

### Important Notices

#### ⚠️ Educational Use Only

This repository is intentionally designed for training purposes and is **not** for production use.

#### 🔐 Security Practices

**This repository:**
- ✅ Contains NO production credentials
- ✅ Contains NO customer data
- ✅ Contains NO sensitive business information
- ✅ Uses placeholders for all environment values
- ✅ Demonstrates DEFENSIVE security only
- ✅ Follows Azure and GitHub security best practices

**This repository does NOT:**
- ❌ Include exploitation code
- ❌ Demonstrate offensive techniques
- ❌ Contain attack payloads
- ❌ Show privilege escalation methods
- ❌ Include weaponized exploits
- ❌ Provide malware examples

### Reporting Security Issues

If you discover a security vulnerability in this educational project:

1. **Do NOT** open a public GitHub issue
2. **Email** security-report@ninjapawsconsulting.com
3. **Include:**
   - Detailed description of the vulnerability
   - Steps to reproduce (if applicable)
   - Potential impact assessment
   - Suggested remediation (if known)

4. **Expect:** Response within 48 hours

### Vulnerability Disclosure

For vulnerabilities in the training environment itself:

- We appreciate responsible disclosure
- Educational projects may move at different pace than production systems
- Fixes will be prioritized based on impact to learning objectives
- Your contribution will be acknowledged in release notes

### Security Scanning

This repository uses:

- **GitHub Security Features:**
  - Secret scanning
  - Dependency alerts
  - Code scanning

- **Container Security:**
  - Trivy image scanning
  - Snyk vulnerability analysis
  - Microsoft Defender for Cloud

- **Infrastructure Security:**
  - Azure Policy scanning
  - RBAC enforcement
  - Managed Identity authentication

### Secure Configuration

#### Local Development

```bash
# Never commit credentials
echo "SECRETS GO HERE" > .env.local
git add .gitignore  # Ensure .env.local is ignored

# Use environment variables
export AZURE_SUBSCRIPTION_ID="<placeholder>"
export AZURE_TENANT_ID="<placeholder>"
```

#### Azure Deployment

- Use Managed Identity (not access keys)
- Enable RBAC (role-based access control)
- Use Azure Key Vault for secrets (if needed)
- Monitor with Defender for Cloud

#### GitHub Actions

- Use OIDC federated identity (not PATs)
- Scope permissions minimally
- Use environment-specific secrets
- Review workflow logs (don't commit secrets)

### Best Practices for Training

When using this project:

1. **Use placeholders** for sensitive values
2. **Never hardcode** credentials anywhere
3. **Review** all code before deployment
4. **Test locally** in safe environment
5. **Monitor** deployments with Defender
6. **Clean up** resources when done
7. **Report** any security concerns responsibly

### Compliance

This project aims to follow:

- ✅ Microsoft Security Best Practices
- ✅ Azure Well-Architected Framework
- ✅ OWASP Top 10
- ✅ Container Security Standards
- ✅ GitHub Security Guidelines

### Educational Curriculum

The project teaches secure practices including:

- Vulnerability detection
- Patch management
- Secure supply chain
- Container security
- Code-to-runtime visibility
- Monitoring and alerting
- Incident response

### License & Terms

MIT License with educational restrictions.

See [LICENSE](LICENSE) file for complete terms.

### Contact

- **Repository:** https://github.com/ninjapaw/ninjapaws-cloud-security-dojo
- **Issues:** Use GitHub Issues for non-security topics
- **Discussions:** Use GitHub Discussions for questions
- **Security:** See "Reporting Security Issues" section above

---

**Remember:** Security is everyone's responsibility. Please use this project responsibly and help us keep the training environment safe and secure for all learners.

🥷 **Stay safe, learn hard!** 🛡🐾
