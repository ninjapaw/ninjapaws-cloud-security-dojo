# 🎓 Hands-On Lab Guide

Complete security training exercises for the Ninja Paws Cloud Security Dojo.

## 📅 Training Path

- **Level 1:** Beginner (1-2 hours) - Understand vulnerability detection
- **Level 2:** Intermediate (2-4 hours) - Create and validate remediation
- **Level 3:** Advanced (4+ hours) - Full cloud deployment and monitoring

## 🥋 Level 1: Vulnerability Detection

### Objective

Understand how automated scanning identifies security vulnerabilities in container images.

### Time Required

**30-60 minutes**

### Prerequisites

- Docker installed
- Git installed
- GitHub account (optional)

### Lab Steps

#### Step 1: Run the Application (10 min)

```bash
# Clone repository
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo

# Start with Docker Compose
docker-compose up -d

# Verify it's running
docker-compose ps

# Access homepage
open http://localhost:8080
```

**What to look for:**
- 🥷 Ninja Paws branding
- ⚠️ Vulnerability status: "Vulnerable"
- 📋 NGINX version: 1.30.3
- 🔴 CVE-2026-42533 displayed

#### Step 2: Understand the Vulnerability (10 min)

Check the API endpoint for vulnerability details:

```bash
curl http://localhost:8080/api/status | jq '.vulnerability'
```

Expected output:
```json
{
  "cve_id": "CVE-2026-42533",
  "status": "vulnerable",
  "description": "NGINX HTTP/2 CONTINUATION Frames Memory Corruption"
}
```

**Questions to answer:**
1. What is CVE-2026-42533?
2. Why is it dangerous?
3. What component is affected?
4. What's the recommended action?

#### Step 3: Scan the Docker Image (15 min)

```bash
# Build the image
docker build -t ninjapaws-dojo:vulnerable .

# Scan with Trivy
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image ninjapaws-dojo:vulnerable

# Save results
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --format json ninjapaws-dojo:vulnerable > scan-results.json
```

**Analyze the results:**
```bash
# View scan summary
jq '.Results[] | .Vulnerabilities' scan-results.json

# Count critical vulnerabilities
jq '[.Results[].Vulnerabilities[] | select(.Severity=="CRITICAL")] | length' scan-results.json

# Find CVE-2026-42533
jq '.Results[].Vulnerabilities[] | select(.VulnerabilityID=="CVE-2026-42533")' scan-results.json
```

#### Step 4: Document Findings (15 min)

Create a file `FINDINGS.md`:

```markdown
# Vulnerability Scan Results

## Scan Details
- Date: [today's date]
- Image: ninjapaws-dojo:vulnerable
- Scanner: Trivy

## Findings

### Critical Vulnerabilities
- **CVE-2026-42533** - NGINX HTTP/2 CONTINUATION Frames Memory Corruption
  - Component: NGINX 1.30.3
  - Severity: HIGH
  - Impact: Memory corruption via malformed HTTP/2 frames
  - Remediation: Update to NGINX 1.30.4+

### Summary
- Total Vulnerabilities: [X]
- Critical: [X]
- High: [X]
- Medium: [X]
- Low: [X]

## Recommendation
Implement urgent patching for CVE-2026-42533 before production deployment.
```

#### Step 5: Review GitHub Actions (10 min)

If you fork the repository:

1. Go to GitHub repository
2. Click "Actions" tab
3. Observe workflows:
   - 🛡 Detect Vulnerability
   - ⚔️ Deploy to Azure
   - ✅ Remediation Validation
4. Review workflow configurations
5. Understand trigger events

**Learning Points:**
✅ Automated scanning detects vulnerabilities  
✅ GitHub Actions integrate with security tools  
✅ Results guide remediation decisions  
✅ Continuous monitoring is essential

---

## 🥋 Level 2: Remediation & Validation

### Objective

Apply security updates and validate that vulnerabilities are resolved.

### Time Required

**1-2 hours**

### Prerequisites

- Completed Level 1
- Git basics
- GitHub account with repository access

### Lab Steps

#### Step 1: Plan the Remediation (15 min)

Create `REMEDIATION_PLAN.md`:

```markdown
# CVE-2026-42533 Remediation Plan

## Vulnerability
- CVE ID: CVE-2026-42533
- Component: NGINX
- Current Version: 1.30.3
- Target Version: 1.30.4

## Changes Required
1. Update Dockerfile NGINX version
2. Update environment variables
3. Test application functionality
4. Scan updated image

## Validation Criteria
- [ ] Docker image builds successfully
- [ ] No critical CVEs detected
- [ ] All endpoints respond (/, /health, /api/status)
- [ ] Health check passes
- [ ] Vulnerability status shows "remediated"

## Rollback Plan
If validation fails, revert to previous version and investigate.

## Timeline
- Implementation: 30 minutes
- Testing: 15 minutes
- Validation: 15 minutes
- Total: ~1 hour
```

#### Step 2: Create Feature Branch (5 min)

```bash
# Create and checkout branch
git checkout -b fix/cve-2026-42533

# Verify you're on the right branch
git branch
git status
```

#### Step 3: Update Dockerfile (10 min)

Edit `Dockerfile` and make these changes:

**Before:**
```dockerfile
RUN apt-get update && apt-get install -y \
    nginx=1.30.3-1~noble \
```

**After:**
```dockerfile
RUN apt-get update && apt-get install -y \
    nginx=1.30.4-1~noble \
```

Also update:
```dockerfile
# Change from:
ENV NGINX_VERSION=1.30.3
ENV VULNERABILITY_STATUS=vulnerable

# Change to:
ENV NGINX_VERSION=1.30.4
ENV VULNERABILITY_STATUS=remediated
```

#### Step 4: Update entrypoint.sh (5 min)

Edit `entrypoint.sh` and update the startup message:

```bash
# Change from:
echo "🛡 NGINX Version: 1.30.3 (Intentionally Vulnerable for Training)"

# Change to:
echo "🛡 NGINX Version: 1.30.4 (Vulnerability Patched)"
```

#### Step 5: Test Locally (20 min)

```bash
# Rebuild the image
docker build -t ninjapaws-dojo:remediated .

# Run the container
docker run -d \
  -p 8888:80 \
  -p 3001:3000 \
  --name dojo-test \
  -e NGINX_VERSION=1.30.4 \
  -e VULNERABILITY_STATUS=remediated \
  ninjapaws-dojo:remediated

# Give it time to start
sleep 5

# Test endpoints
echo "Testing endpoints..."
curl -s http://localhost:8888/ | head -20
echo ""
echo "Health check:"
curl -s http://localhost:8888/health | jq .
echo ""
echo "API Status:"
curl -s http://localhost:8888/api/status | jq '.'

# Verify vulnerability status
curl -s http://localhost:8888/api/status | jq '.vulnerability.status'

# Should output: "remediated"

# Stop the test container
docker stop dojo-test
docker rm dojo-test
```

**Expected Results:**
- ✅ Container starts successfully
- ✅ All endpoints respond
- ✅ Health status: "healthy"
- ✅ Vulnerability status: "remediated"
- ✅ NGINX version: 1.30.4
- ✅ No errors in logs

#### Step 6: Scan the Updated Image (15 min)

```bash
# Scan updated image
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image ninjapaws-dojo:remediated > remediated-scan.json

# Compare scans
echo "Original scan:"
jq '[.Results[].Vulnerabilities[] | select(.VulnerabilityID=="CVE-2026-42533")]' scan-results.json

echo "Remediated scan:"
jq '[.Results[].Vulnerabilities[] | select(.VulnerabilityID=="CVE-2026-42533")]' remediated-scan.json

# Analyze results
jq '.Results[] | length' remediated-scan.json
```

**Expected Outcome:**
- ✅ CVE-2026-42533 is no longer present
- ✅ Total vulnerability count decreased
- ✅ Image is safe for deployment

#### Step 7: Commit and Push (10 min)

```bash
# Stage changes
git add Dockerfile entrypoint.sh

# Create descriptive commit
git commit -m "🛡️ Security: Patch CVE-2026-42533 - Update NGINX to 1.30.4

- Update NGINX from 1.30.3 (vulnerable) to 1.30.4 (patched)
- Fixes CVE-2026-42533: HTTP/2 CONTINUATION Frames Memory Corruption
- No breaking changes, backward compatible
- All endpoints tested and verified"

# Push to GitHub
git push origin fix/cve-2026-42533
```

#### Step 8: Create Pull Request (10 min)

On GitHub:

1. Go to your repository
2. Click "Create Pull Request"
3. Set branch: `fix/cve-2026-42533` → `main`
4. Use the PR template
5. Fill in:
   - Summary
   - Purpose
   - Security impact
   - Version before/after
   - Validation results
6. Submit PR

#### Step 9: Monitor Validation Workflow (15 min)

```bash
# Watch GitHub Actions workflows
# On GitHub:
# 1. Click "Actions" tab
# 2. Find PR-related workflows
# 3. Monitor:
#    - Validation workflow progress
#    - Security scan results
#    - Test results
```

**Check for:**
- ✅ All status checks pass
- ✅ Vulnerability scan succeeds
- ✅ No high-severity CVEs
- ✅ All tests pass
- ✅ Ready for merge

**Learning Points:**
✅ Systematic approach to remediation  
✅ Automated validation catches issues  
✅ Testing before production is critical  
✅ Scans confirm fixes  

---

## 🥋 Level 3: Full Deployment & Monitoring

### Objective

Deploy the patched application to Azure and monitor with Defender for Cloud.

### Time Required

**2-4 hours**

### Prerequisites

- Completed Levels 1 & 2
- Azure account
- Azure CLI installed
- Microsoft Defender for Cloud access

### Lab Steps

#### Step 1: Prepare Azure Environment (20 min)

```bash
# Install Azure CLI if needed
# https://learn.microsoft.com/en-us/cli/azure/install-azure-cli

# Login to Azure
az login

# Create resource group
az group create \
  --name ninjapaws-dojo-lab \
  --location eastus

# Verify
az group show --name ninjapaws-dojo-lab
```

#### Step 2: Deploy Infrastructure (30 min)

```bash
# Option A: Using script (recommended)
chmod +x scripts/deploy.sh
./scripts/deploy.sh ninjapaws-dojo-lab eastus ninjapawsdojo ninjapaws-dojo-lab-app

# Option B: Manual deployment
az deployment group create \
  --name dojo-lab-deployment \
  --resource-group ninjapaws-dojo-lab \
  --template-file infra/main.bicep \
  --parameters \
    containerRegistryName=ninjapawsdojo \
    appServiceName=ninjapaws-dojo-lab-app \
    location=eastus
```

**What gets deployed:**
- 🏗️ Azure Container Registry
- 📱 Azure App Service
- 🔑 Managed Identity
- 🛡️ Role-based access control

#### Step 3: Build & Push Initial Image (20 min)

```bash
# Get ACR login server
ACR_NAME=ninjapawsdojo
ACR_LOGIN=$(az acr show --name $ACR_NAME --query loginServer -o tsv)

# Login to ACR
az acr login --name $ACR_NAME

# Build and push vulnerable version
az acr build \
  --registry $ACR_NAME \
  --image ninjapaws-dojo:1.30.3 \
  --image ninjapaws-dojo:vulnerable \
  .

echo "Vulnerable image pushed to ACR"
```

#### Step 4: Deploy Vulnerable Version (15 min)

```bash
# Get ACR password for App Service
az acr update --name $ACR_NAME --admin-enabled true
REGISTRY_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value -o tsv)

# Update App Service with vulnerable image
az webapp config container set \
  --name ninjapaws-dojo-lab-app \
  --resource-group ninjapaws-dojo-lab \
  --docker-custom-image-name $ACR_LOGIN/ninjapaws-dojo:vulnerable \
  --docker-registry-server-url https://$ACR_LOGIN \
  --docker-registry-server-username $ACR_NAME \
  --docker-registry-server-password "$REGISTRY_PASSWORD"

# Wait for deployment
echo "Deployment in progress..."
sleep 60

# Get App URL
APP_URL=$(az webapp show \
  --resource-group ninjapaws-dojo-lab \
  --name ninjapaws-dojo-lab-app \
  --query defaultHostName -o tsv)

echo "Application deployed!"
echo "URL: https://$APP_URL"
```

#### Step 5: Verify Vulnerable Deployment (10 min)

```bash
# Test the application
APP_URL=$(az webapp show \
  --resource-group ninjapaws-dojo-lab \
  --name ninjapaws-dojo-lab-app \
  --query defaultHostName -o tsv)

# Test endpoints
curl https://$APP_URL/health
curl https://$APP_URL/api/status | jq '.vulnerability'

# Verify vulnerable status
echo "Checking vulnerability status..."
VULN_STATUS=$(curl -s https://$APP_URL/api/status | jq -r '.vulnerability.status')
echo "Status: $VULN_STATUS"
# Expected: "vulnerable"
```

#### Step 6: Monitor with Defender for Cloud (20 min)

```bash
# In Azure Portal:
# 1. Search for "Defender for Cloud"
# 2. Click "Container Registries"
# 3. Look for: ninjapawsdojo
# 4. Check scan results
# 5. Find CVE-2026-42533
```

**Document observations:**
- ⚠️ Vulnerability detected in ACR
- 🔴 High severity issue
- 📦 Affected component: NGINX 1.30.3
- 🛡️ Monitoring status active

#### Step 7: Deploy Remediated Version (20 min)

```bash
# Make sure you're on the fix branch with your changes
git checkout fix/cve-2026-42533

# Build and push remediated version
az acr build \
  --registry $ACR_NAME \
  --image ninjapaws-dojo:1.30.4 \
  --image ninjapaws-dojo:remediated \
  .

echo "Remediated image pushed to ACR"

# Update App Service
az webapp config container set \
  --name ninjapaws-dojo-lab-app \
  --resource-group ninjapaws-dojo-lab \
  --docker-custom-image-name $ACR_LOGIN/ninjapaws-dojo:remediated \
  --docker-registry-server-url https://$ACR_LOGIN \
  --docker-registry-server-username $ACR_NAME \
  --docker-registry-server-password "$REGISTRY_PASSWORD"

# Wait for deployment
sleep 60

echo "Remediated version deployed!"
```

#### Step 8: Verify Remediation (10 min)

```bash
# Test the remediated application
curl https://$APP_URL/api/status | jq '.vulnerability'

# Verify remediated status
VULN_STATUS=$(curl -s https://$APP_URL/api/status | jq -r '.vulnerability.status')
echo "Status: $VULN_STATUS"
# Expected: "remediated"
```

#### Step 9: Monitor Defender Changes (15 min)

```bash
# In Azure Portal:
# 1. Go back to Defender for Cloud
# 2. Check Container Registries again
# 3. Observe changes:
#    - CVE-2026-42533 status change
#    - New scan results
#    - Updated image information
```

**Document observations:**
- ✅ Vulnerability cleared
- 📈 Security posture improved
- 🕐 Scan completion time
- 🔄 Deployment status

#### Step 10: Create Lab Report (30 min)

Create `LAB_REPORT.md`:

```markdown
# Lab Report: CVE-2026-42533 Remediation

## Executive Summary
Successfully detected, remediated, and validated NGINX HTTP/2 vulnerability in cloud environment.

## Timeline
- Start time: [time]
- Vulnerable deployment: [time]
- Detection confirmed: [time]
- Remediated deployment: [time]
- Validation complete: [time]
- Total duration: [duration]

## Vulnerable Phase (NGINX 1.30.3)
- Application URL: https://...
- CVE Status: Detected ⚠️
- Defender for Cloud: Alert active
- Health Check: Passing
- Endpoints: All responding

### Scan Results
- Total Vulnerabilities: [X]
- Critical: CVE-2026-42533
- Application Status: Vulnerable

## Remediation Phase
- Changes Made:
  - NGINX 1.30.3 → 1.30.4
  - Environment variables updated
  - Tests conducted and passed
  
## Remediated Phase (NGINX 1.30.4)
- Application URL: https://...
- CVE Status: Remediated ✅
- Defender for Cloud: Alert cleared
- Health Check: Passing
- Endpoints: All responding

### Scan Results
- Total Vulnerabilities: [X] (reduced)
- Critical: None
- Application Status: Secure

## Key Learnings
1. [Learning point]
2. [Learning point]
3. [Learning point]

## Recommendations
1. Implement automated dependency updates (Dependabot)
2. Set up continuous monitoring with Defender
3. Establish regular security review schedule

## Conclusion
Successfully demonstrated complete security lifecycle: detection → remediation → validation.
```

#### Step 11: Cleanup (10 min)

```bash
# Delete resources to avoid charges
az group delete \
  --name ninjapaws-dojo-lab \
  --yes \
  --no-wait

echo "Resources deletion in progress..."
```

**Learning Points:**
✅ Full cloud deployment workflow  
✅ Infrastructure as Code with Bicep  
✅ Managed Identity authentication  
✅ Defender for Cloud monitoring  
✅ Real-world security validation  

---

## 🎯 Lab Completion Checklist

### Level 1: Vulnerability Detection
- [ ] Application running locally
- [ ] Vulnerability identified in API
- [ ] Docker image scanned
- [ ] Findings documented
- [ ] GitHub Actions workflows reviewed

### Level 2: Remediation & Validation
- [ ] Feature branch created
- [ ] Dockerfile updated
- [ ] Local testing completed
- [ ] Image scanned (no CVE)
- [ ] Pull request created
- [ ] GitHub Actions validation passed
- [ ] Changes committed properly

### Level 3: Cloud Deployment
- [ ] Azure environment created
- [ ] Infrastructure deployed
- [ ] Vulnerable image deployed
- [ ] Vulnerability confirmed in Defender
- [ ] Remediated image deployed
- [ ] Vulnerability cleared in Defender
- [ ] Lab report completed
- [ ] Resources cleaned up

## 🏆 Certification

Upon completion of all three levels, you understand:

✅ Vulnerability detection methodologies  
✅ Secure remediation practices  
✅ Automated validation techniques  
✅ Cloud security monitoring  
✅ Complete supply chain security  

---

## 📞 Support & Questions

- 📖 Review [README.md](../README.md)
- 📚 Check [VULNERABILITY_GUIDE.md](VULNERABILITY_GUIDE.md)
- ☁️ Review [AZURE_DEPLOYMENT.md](AZURE_DEPLOYMENT.md)
- 🤝 Open a GitHub Issue
- 💬 Start a GitHub Discussion

---

**Congratulations on completing the Ninja Paws Cloud Security Dojo! 🥷🛡🐾**
