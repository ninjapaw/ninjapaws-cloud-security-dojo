# Contributing to Ninja Paws Cloud Security Dojo

Thank you for your interest in contributing to the Ninja Paws Cloud Security Dojo! This is an educational project designed for security training.

## 🥷 Our Mission

We create safe, educational environments to teach cloud security best practices. All contributions should support this mission.

## 📋 Code of Conduct

- Be respectful and inclusive
- Focus on learning and education
- Avoid exploitation or offensive content
- Help others understand security concepts

## 🛠️ How to Contribute

### Reporting Issues

Found a bug or have a suggestion?

1. Search existing issues to avoid duplicates
2. Provide a clear description
3. Include steps to reproduce (if applicable)
4. Mention your environment (OS, versions, etc.)

### Suggesting Enhancements

Great ideas are welcome!

1. Describe the enhancement
2. Explain the learning value
3. Suggest implementation approach
4. Consider impact on training flow

### Submitting Pull Requests

We love pull requests! Here's how:

#### Before You Start

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Read the guidelines below

#### Making Changes

- Keep changes focused and clear
- Write descriptive commit messages
- Follow existing code style
- Test your changes locally
- Update documentation as needed

#### Commit Message Format

```
Type: Brief description

Longer explanation if needed. Reference issues, PRs, or learning objectives.

Types: feature|fix|docs|test|security|refactor
```

Examples:

```
docs: Add exercise for vulnerability detection

security: Update NGINX from 1.30.3 to 1.30.4

test: Add health check validation test
```

#### Pull Request Process

1. Update README.md with any new features
2. Add tests if applicable
3. Ensure Docker builds successfully
4. Verify endpoints work correctly
5. Write clear PR description:
   - What changed?
   - Why did it change?
   - How does it benefit learning?
   - Any breaking changes?

## 📝 Documentation Guidelines

### Writing Style

- Clear and concise
- Explain concepts for learners
- Provide examples
- Include troubleshooting tips
- Use appropriate terminology

### Code Comments

```javascript
// Good: Explains the why
// Proxy requests to Node.js app to demonstrate layered architecture
location / {
  proxy_pass http://nodejs_app;
}

// Avoid: Obvious comments
// Set proxy pass
location / {
  proxy_pass http://nodejs_app;
}
```

## 🔐 Security Guidelines

### NEVER commit:

- ✅ Credentials, API keys, tokens
- ✅ Connection strings or secrets
- ✅ Private certificates
- ✅ Sensitive company information
- ✅ Customer data

### Use placeholders:

```bash
# Good
export AZURE_SUBSCRIPTION_ID="<your-subscription-id>"
export AZURE_TENANT_ID="<your-tenant-id>"

# Bad
export AZURE_SUBSCRIPTION_ID="12345678-1234-1234-1234-123456789012"
```

## 🧪 Testing

### Local Testing

```bash
# Build Docker image
docker build -t ninjapaws-dojo:test .

# Run container
docker-compose up -d

# Test endpoints
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/api/status

# View logs
docker-compose logs -f
```

### Validation Checklist

- [ ] Application starts without errors
- [ ] All endpoints respond correctly
- [ ] Health check passes
- [ ] Docker image builds successfully
- [ ] No sensitive data in code or logs
- [ ] Documentation is accurate

## 📚 Contribution Ideas

### Needed Contributions

- ✅ Additional training exercises
- ✅ Enhanced documentation
- ✅ CI/CD workflow improvements
- ✅ Security hardening suggestions
- ✅ Additional vulnerability examples
- ✅ Azure Bicep optimizations
- ✅ Multi-language support

### Exercise Template

```markdown
## Exercise: [Title]

**Objective:** What will students learn?

**Prerequisites:** What should they know first?

**Steps:**
1. Step one
2. Step two
3. etc.

**Expected Output:** What should they see?

**Learning Points:** What's the key takeaway?

**Extension:** Advanced variations
```

## 🎯 Development Workflow

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create** a feature branch
4. **Make** your changes
5. **Test** thoroughly
6. **Push** to your fork
7. **Create** a Pull Request
8. **Respond** to review feedback
9. **Merge** when approved

## 📦 Release Process

New versions follow semantic versioning (MAJOR.MINOR.PATCH):

- MAJOR: Breaking changes
- MINOR: New features
- PATCH: Bug fixes

Example: v1.0.0, v1.1.0, v1.1.1

## 🐾 Getting Help

- Review existing issues and discussions
- Check documentation in `/docs`
- Read through workflows in `.github/workflows`
- Ask questions in issues with `question` label

## 🙏 Thank You!

Your contributions help make cloud security education better for everyone. Thank you for being part of the Ninja Paws community!

---

**Ready to contribute? Let's make security training amazing together! 🥷🛡🐾**
