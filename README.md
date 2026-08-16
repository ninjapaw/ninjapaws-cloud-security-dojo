# 🥷 Ninja Paws Cloud Security Dojo

**Master the art of cloud security one vulnerability at a time.**

A public Azure security demonstration and educational workshop environment showcasing vulnerability detection, remediation, and validation across a complete cloud-native supply chain.

## 🎯 Overview

The Ninja Paws Cloud Security Dojo is a hands-on training environment that demonstrates how [GitHub Advanced Security](https://github.com/features/security), [Microsoft Defender for Cloud](https://azure.microsoft.com/en-us/products/defender-for-cloud/), [Defender for DevOps](https://azure.microsoft.com/en-us/products/defender-for-devops/), [Azure Container Registry](https://azure.microsoft.com/en-us/products/container-registry/), and [Azure App Service](https://azure.microsoft.com/en-us/products/app-service/) work together to detect, remediate, and validate container vulnerabilities in a production-like environment.

### 🏯 Perfect For

- Microsoft customers wanting to understand cloud security
- Security teams learning vulnerability detection
- Cloud architects designing secure infrastructure
- Developers learning secure coding practices
- Conference demonstrations
- Security workshops
- Community events
- Training sessions

## 📋 Educational Disclaimer

**⚠️ Important:** This environment intentionally contains a vulnerable software version for educational detection and remediation demonstrations. This repository contains **no customer data, production credentials, or business-sensitive information**. All values are examples and placeholders only.

This repository demonstrates **defensive security practices only** — not exploitation, offensive techniques, or attack payloads.

## 🛡 Current Vulnerability

### CVE-2026-42533: NGINX HTTP/2 CONTINUATION Frames Memory Corruption

**Training Version:** NGINX Open Source 1.30.3  
**Vulnerable Component:** NGINX web server  
**Status:** 🚨 Vulnerable (intentional for training)

```
Branch: main
NGINX: 1.30.3
Status: Vulnerable
Action: Detect and remediate on fix/cve-2026-42533 branch
```

### ⚔️ Remediation Mission

**Remediation Branch:** `fix/cve-2026-42533`  
**Target Version:** NGINX Open Source 1.30.4 or later  
**Expected:** Pull request with before/after vulnerability status

## 🏗️ Architecture

```
GitHub Repository
    ↓
GitHub Actions (Detect)
    ↓
Azure Container Registry (Build & Scan)
    ↓
Azure App Service Linux Container (Deploy)
    ↓
Microsoft Defender for Cloud (Monitor & Validate)
```

### Infrastructure

- **Container Registry:** Azure Container Registry (Basic SKU)
- **App Hosting:** Azure App Service (Linux Container)
- **Authentication:** Managed Identity
- **Infrastructure as Code:** Bicep
- **CI/CD:** GitHub Actions
- **Monitoring:** Microsoft Defender for Cloud

## 📦 Technology Stack

- **Base OS:** Ubuntu 24.04
- **Container Runtime:** Docker
- **Web Server:** NGINX Open Source (vulnerable version)
- **Runtime:** Node.js
- **Framework:** Express.js
- **Infrastructure:** Bicep, Azure Resource Manager

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- Node.js 18+
- Git

### Local Development

```bash
# Clone repository
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo

# Start with Docker Compose
docker-compose up -d

# Access the application
# Homepage: http://localhost:8080
# Health: http://localhost:8080/health
# API Status: http://localhost:8080/api/status
```

### GitHub Codespaces

This repo includes a [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json) with Docker-in-Docker and the Azure CLI preinstalled, so you can open it directly in a Codespace with no extra setup:

1. Click **Code → Codespaces → Create codespace on main**
2. Wait for the container to build (runs `npm install` automatically)
3. Run `docker-compose up -d` in the terminal
4. VS Code will auto-forward ports `8080` and `3000` — use the **Ports** tab to open them in a browser

Copy [`.env.example`](.env.example) to `.env` if you want to override defaults such as `VULNERABILITY_STATUS` or `PORT`.

### Build Docker Image

```bash
# Build the image
docker build -t ninjapaws-dojo:vulnerable .

# Run the container
docker run -p 8080:80 -p 3000:3000 \
  -e NGINX_VERSION=1.30.3 \
  -e VULNERABILITY_STATUS=vulnerable \
  ninjapaws-dojo:vulnerable
```

## 📱 Application Endpoints

### `/` - Homepage
Interactive training dashboard displaying:
- Current NGINX version
- CVE identifier and status
- Vulnerability detection status
- Microsoft Defender workflow integration
- Educational materials and disclaimers

### `/health` - Health Check
JSON health status endpoint for monitoring systems.

```bash
curl http://localhost:8080/health
```

```json
{
  "status": "healthy",
  "timestamp": "2026-08-14T12:34:56.789Z",
  "environment": "training"
}
```

### `/api/status` - Detailed Status
Comprehensive API status with vulnerability details.

```bash
curl http://localhost:8080/api/status
```

```json
{
  "environment": "Ninja Paws Cloud Security Dojo",
  "status": "running",
  "nginx_version": "1.30.3",
  "vulnerability": {
    "cve_id": "CVE-2026-42533",
    "status": "vulnerable",
    "description": "NGINX HTTP/2 CONTINUATION Frames Memory Corruption"
  },
  "host": "container-hostname",
  "platform": "linux",
  "arch": "x64",
  "uptime": 1234.56,
  "timestamp": "2026-08-14T12:34:56.789Z"
}
```

## 🔄 Workflow: Detect & Remediate

### Step 1: Detect Vulnerability
1. Push code to main branch
2. GitHub Actions workflow triggers
3. Container image built and pushed to ACR
4. Microsoft Defender for Cloud scans image
5. Vulnerability detected: ✅ CVE-2026-42533

### Step 2: Create Remediation
1. Create feature branch `fix/cve-2026-42533`
2. Update Dockerfile: NGINX 1.30.3 → 1.30.4
3. Update environment variables
4. Commit and push
5. Open Pull Request

### Step 3: Validate Remediation
1. Pull request triggers validation workflow
2. New container image built with NGINX 1.30.4
3. Image scanned by Microsoft Defender
4. Vulnerability remediated: ✅ Status cleared
5. Review, approve, and merge

### Step 4: Monitor in Azure
1. Defender for Cloud confirms remediation
2. App Service deployment reflects patched version
3. Health checks validate functionality
4. Training session demonstrates complete supply chain

## 📊 GitHub Actions Workflows

### `.github/workflows/detect-vulnerability.yml`
Automatically triggers on:
- Push to main branch
- Pull requests to main
- Manual trigger

Actions:
- Build Docker image
- Push to Azure Container Registry
- Scan with Microsoft Defender for Cloud
- Generate security report

### `.github/workflows/deploy.yml`
Automatically triggers on:
- Merge to main branch
- Manual trigger

Actions:
- Build and push image to ACR
- Deploy to Azure App Service
- Run health checks
- Notify deployment status

## 🏗️ Azure Infrastructure

### Bicep Templates

Infrastructure as Code using Bicep for reproducible deployments.

**Resources:**
- Azure Container Registry (Basic SKU)
- Azure App Service Plan (Linux)
- Azure App Service (Container)
- Managed Identity for authentication

**Deploy:**

```bash
# Authenticate to Azure
az login

# Create resource group
az group create \
  --name ninjapaws-dojo \
  --location eastus

# Deploy Bicep template
az deployment group create \
  --name dojo-deployment \
  --resource-group ninjapaws-dojo \
  --template-file infra/main.bicep \
  --parameters \
    containerRegistryName=ninjapawsdojo \
    appServiceName=ninjapaws-dojo
```

## 🛠️ Configuration

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NGINX_VERSION` | `1.30.3` | NGINX version string |
| `VULNERABILITY_STATUS` | `vulnerable` | Current vulnerability status |
| `ENVIRONMENT` | `training` | Environment name |
| `PORT` | `3000` | Node.js application port |
| `DEFENDER_ENABLED` | `false` | Microsoft Defender monitoring status |

### Docker Compose Override

Create `.env.local` to override:

```env
NGINX_VERSION=1.30.3
VULNERABILITY_STATUS=vulnerable
ENVIRONMENT=training
PORT=3000
```

## 📚 Learning Objectives

This dojo teaches:

✅ **Vulnerability Detection**
- Container scanning
- Image analysis
- Security baseline validation

✅ **Vulnerability Remediation**
- Dependency updates
- Configuration hardening
- Testing before/after

✅ **Secure Supply Chain**
- GitHub Advanced Security
- Container registry security
- Image signing and validation

✅ **Code-to-Runtime Visibility**
- Application instrumentation
- Health monitoring
- Defender integration

✅ **Container Image Security**
- Layer analysis
- Dependency scanning
- CVE tracking

✅ **GitHub Security Workflows**
- Secret scanning
- Dependency alerts
- Pull request validation

✅ **Microsoft Defender Capabilities**
- Defender for Cloud
- Defender for DevOps
- Container image scanning

## 🚫 What This Is NOT

This repository explicitly does **NOT** demonstrate:

- ❌ Exploitation techniques
- ❌ Offensive security methods
- ❌ Attack payloads or proof-of-concepts
- ❌ Privilege escalation
- ❌ Denial of service attacks
- ❌ Malware creation
- ❌ Vulnerability weaponization

**Defensive guidance only.**

## 🔐 Security Standards

### Repository Protections

- ✅ No customer data
- ✅ No business-sensitive information
- ✅ No production credentials
- ✅ No API keys or tokens
- ✅ No subscription IDs or tenant IDs
- ✅ No connection strings
- ✅ No certificates or private keys
- ✅ No private endpoint configurations

All sensitive values use placeholders and environment variables.

### Branch Protections

```
main branch:
  - Require pull request reviews
  - Require status checks to pass
  - Require branches to be up to date
  - Include administrators
```

## 📋 Pull Request Template

All pull requests include:
- Summary of changes
- Purpose and training objective
- Security impact assessment
- Before/after versions
- Validation steps
- Defender for Cloud validation notes

Example PR for remediation:

```markdown
## Summary
Update NGINX from 1.30.3 (vulnerable) to 1.30.4 (patched)

## Purpose
Demonstrate vulnerability remediation and validation workflow

## Security Impact
- Fixes CVE-2026-42533
- No breaking changes
- Backward compatible

## Versions
- Before: NGINX 1.30.3
- After: NGINX 1.30.4

## Validation
- [ ] Image builds successfully
- [ ] Health checks pass
- [ ] Defender for Cloud confirms no vulnerabilities
- [ ] Application functionality verified

## Defender Notes
Vulnerability status changes from "vulnerable" to "remediated"
```

## 🎓 Hands-On Exercises

### Exercise 1: Detect Vulnerability
**Objective:** Understand how automated scanning detects vulnerabilities

**Steps:**
1. Clone repository
2. Review main branch with NGINX 1.30.3
3. Observe GitHub Actions workflow execution
4. Check Microsoft Defender for Cloud findings
5. Document discovered vulnerabilities

### Exercise 2: Create Remediation
**Objective:** Apply security updates and validate

**Steps:**
1. Create feature branch from main
2. Update Dockerfile NGINX version to 1.30.4
3. Update environment variables
4. Commit with security context in message
5. Push and create pull request

### Exercise 3: Validate Fix
**Objective:** Confirm remediation through automated checks

**Steps:**
1. Review pull request
2. Monitor GitHub Actions workflow
3. Check Microsoft Defender scan results
4. Verify vulnerability is resolved
5. Approve and merge

### Exercise 4: Deploy & Monitor
**Objective:** Deploy to Azure and monitor with Defender

**Steps:**
1. Monitor main branch deployment
2. Check Azure App Service status
3. Review Defender for Cloud dashboard
4. Verify application health
5. Document complete workflow

## 🌐 Use Cases

### Conference Demonstrations
- Live demo of complete security workflow
- 15-30 minute presentation
- Show detection → remediation → validation
- Audience can follow along

### Security Training
- 2-4 hour hands-on workshop
- Multiple parallel exercises
- Step-by-step guidance
- Real-world scenario simulation

### Customer Workshops
- Demonstrate security best practices
- Show integration possibilities
- Discuss architecture patterns
- Plan customer implementations

### Community Events
- Beginners-friendly security intro
- Public repository for learning
- Self-paced training materials
- Starter template for advanced scenarios

## 📞 Support

- **Documentation:** See `/docs` folder
- **Issues:** GitHub Issues for questions and improvements
- **Discussions:** GitHub Discussions for general topics
- **Contributing:** Pull requests welcome (see `CONTRIBUTING.md`)

## 📄 License

MIT License - See LICENSE file

---

## 🐾 Branding Guide

**Ninja Paws Consulting** | Cloud Security Training Environment

### Terminology

| Term | Emoji | Usage |
|------|-------|-------|
| Ninja | 🥷 | Speed, precision, skill |
| Defender | 🛡 | Protection, monitoring |
| Paws | 🐾 | Identity, friendly approach |
| Dojo | 🏯 | Training, learning |
| Remediation Mission | ⚔️ | Challenge, objective |
| Security Validation | ✅ | Success, completion |

### Colors

- Primary: Navy Blue (#1e3c72)
- Secondary: Cyan Blue (#2a5298)
- Success: Green (#28a745)
- Warning: Orange (#ffc107)
- Danger: Red (#dc3545)

### Tone

Professional, educational, approachable, and encouraging.

---

**Built with 🥷 for cloud security professionals worldwide**
