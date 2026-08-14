# 🏃 Quick Start Guide

Get the Ninja Paws Cloud Security Dojo running in minutes!

## Option 1: Local Development (Fastest)

### Prerequisites

- Docker & Docker Compose
- Node.js 18+ (for local testing)
- Git

### Steps

```bash
# 1. Clone the repository
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo

# 2. Start with Docker Compose
docker-compose up -d

# 3. Wait for startup (~10 seconds)
sleep 10

# 4. Access the application
echo "🏯 Application is running!"
echo "   Homepage: http://localhost:8080"
echo "   Health Check: http://localhost:8080/health"
echo "   API Status: http://localhost:8080/api/status"

# 5. Test endpoints
curl http://localhost:8080/health | jq .
curl http://localhost:8080/api/status | jq .
```

### Stop the Application

```bash
docker-compose down
```

## Option 2: Kubernetes/Docker Direct

```bash
# Build the image
docker build -t ninjapaws-dojo:vulnerable .

# Run the container
docker run -d \
  -p 8080:80 \
  -p 3000:3000 \
  --name ninjapaws-dojo \
  -e NGINX_VERSION=1.30.3 \
  -e VULNERABILITY_STATUS=vulnerable \
  ninjapaws-dojo:vulnerable

# Check it's running
docker ps | grep ninjapaws-dojo

# View logs
docker logs -f ninjapaws-dojo

# Stop the container
docker stop ninjapaws-dojo
docker rm ninjapaws-dojo
```

## Option 3: Azure Cloud Deployment

```bash
# 1. Install Azure CLI
# https://learn.microsoft.com/en-us/cli/azure/install-azure-cli

# 2. Login to Azure
az login

# 3. Run deployment script
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# 4. Watch the deployment
echo "Deployment in progress..."
echo "Check Azure Portal for status"

# 5. Get your app URL
az webapp browse \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app
```

## 🔍 Verify It's Working

### Check Health Endpoint

```bash
curl http://localhost:8080/health
# Expected response:
# {"status":"healthy","timestamp":"2026-08-14T12:34:56.789Z","environment":"training"}
```

### Check API Status

```bash
curl http://localhost:8080/api/status | jq .
# Shows:
# - NGINX version: 1.30.3
# - Vulnerability status: vulnerable
# - CVE-2026-42533 details
```

### View Homepage

Open your browser:
- **Local:** http://localhost:8080
- **Azure:** https://ninjapaws-dojo-app.azurewebsites.net

## 📝 Next Steps

### 1. View the Application

- Open http://localhost:8080 in your browser
- Read the training information
- Check the vulnerability status

### 2. Understand the Vulnerability

- Read [VULNERABILITY_GUIDE.md](docs/VULNERABILITY_GUIDE.md)
- Understand CVE-2026-42533
- Learn the detection workflow

### 3. Create a Remediation

```bash
# Create a new branch
git checkout -b fix/cve-2026-42533

# Edit Dockerfile - change NGINX 1.30.3 to 1.30.4
# Edit entrypoint.sh - update version message

# Commit changes
git add Dockerfile entrypoint.sh
git commit -m "🛡️ Security: Update NGINX to 1.30.4 (fix CVE-2026-42533)"

# Push to GitHub
git push origin fix/cve-2026-42533
```

### 4. Create a Pull Request

On GitHub:
- Go to your fork
- Click "New Pull Request"
- Select `fix/cve-2026-42533` → `main`
- Use the PR template
- Submit for review

### 5. Monitor Workflows

- Watch GitHub Actions workflows run
- Check security scan results
- Review Defender for Cloud integration
- Verify deployment success

## 🎓 Training Exercises

### Exercise 1: Detect Vulnerability (15 minutes)

```bash
# 1. Build the image
docker build -t ninjapaws-dojo:scan .

# 2. Scan for vulnerabilities
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image ninjapaws-dojo:scan

# 3. Identify CVE-2026-42533
# 4. Document your findings
```

### Exercise 2: Remediate (15 minutes)

```bash
# 1. Create feature branch
git checkout -b fix/cve-2026-42533

# 2. Update Dockerfile:
#    - Change: nginx=1.30.3-1~noble → nginx=1.30.4-1~noble
#    - Change: ENV NGINX_VERSION=1.30.3 → 1.30.4
#    - Change: ENV VULNERABILITY_STATUS=vulnerable → remediated

# 3. Rebuild and test locally
docker build -t ninjapaws-dojo:remediated .
docker run -p 8080:80 ninjapaws-dojo:remediated

# 4. Verify it works
curl http://localhost:8080/api/status
```

### Exercise 3: Validate & Deploy (20 minutes)

```bash
# 1. Push branch and create PR
git add Dockerfile entrypoint.sh
git commit -m "🛡️ Security: Patch NGINX 1.30.3 → 1.30.4"
git push origin fix/cve-2026-42533

# 2. Create pull request on GitHub

# 3. Watch GitHub Actions:
#    - Vulnerability detection workflow
#    - Remediation validation workflow
#    - Security scan results

# 4. Review results
#    - Check if CVE-2026-42533 is fixed
#    - Verify all endpoints work
#    - Confirm health checks pass

# 5. Merge PR
#    - On GitHub, merge to main
#    - Triggers deployment workflow
#    - Watch App Service update
```

## 📊 Monitoring

### View Workflow Logs

```bash
# On GitHub:
1. Go to Actions tab
2. Select workflow (e.g., "🛡 Detect Vulnerability")
3. Click run to see logs
4. Check scan results
```

### View Application Logs (Local)

```bash
docker-compose logs -f

# Or for a specific service:
docker-compose logs -f dojo
```

### Monitor in Azure

```bash
# Stream App Service logs
az webapp log tail \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app

# View in browser
az webapp browse \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app
```

## 🆘 Troubleshooting

### Application won't start

```bash
# Check logs
docker-compose logs dojo

# Verify port isn't in use
lsof -i :8080
lsof -i :3000

# Rebuild
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### Port already in use

```bash
# Find process using port
lsof -i :8080

# Kill process (example)
kill -9 <PID>

# Or use different port
docker run -p 9999:80 ninjapaws-dojo:vulnerable
```

### Docker image build fails

```bash
# Check Docker daemon
docker ps

# Clean up old images
docker system prune -a

# Rebuild
docker build --no-cache -t ninjapaws-dojo:vulnerable .
```

### Health check fails

```bash
# Check if container is running
docker-compose ps

# Check logs
docker-compose logs dojo

# Test endpoint manually
docker exec <container-id> curl localhost:3000/health
```

## 📚 Resources

- **Main Documentation:** [README.md](README.md)
- **Vulnerability Guide:** [docs/VULNERABILITY_GUIDE.md](docs/VULNERABILITY_GUIDE.md)
- **Azure Deployment:** [docs/AZURE_DEPLOYMENT.md](docs/AZURE_DEPLOYMENT.md)
- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md)
- **GitHub:** https://github.com/ninjapaw/ninjapaws-cloud-security-dojo

## 💡 Tips

- 📖 Read the README for complete overview
- 🔐 Keep all credentials in environment variables
- 🧪 Test locally before pushing to GitHub
- 📊 Monitor workflows in GitHub Actions
- 🛡️ Check Defender for Cloud regularly
- ✅ Always verify health endpoints

## 🚀 Ready?

You now have everything to:
- ✅ Run the application locally
- ✅ Understand the vulnerability
- ✅ Create remediation
- ✅ Deploy to Azure
- ✅ Monitor with Defender

**Let's start your security training! 🥷**

---

**Questions?** Check the [README.md](README.md) or open a GitHub Issue.
