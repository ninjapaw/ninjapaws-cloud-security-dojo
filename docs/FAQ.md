# 🥷 Ninja Paws Cloud Security Dojo - Frequently Asked Questions

## Getting Started

### Q: What do I need to run this locally?
A: Minimum requirements:
- Docker & Docker Compose (easiest option)
- OR: Node.js 18+, NGINX, and manual setup
- Git for version control
- ~1GB disk space for Docker image

### Q: Can I run this on Windows?
A: Yes! 
- Install Docker Desktop for Windows
- Use WSL2 (Windows Subsystem for Linux)
- Run the same `docker-compose up` command
- See [QUICK_START.md](docs/QUICK_START.md) for details

### Q: How long does it take to get running?
A: About 5-10 minutes:
1. Clone repo (1 min)
2. Run docker-compose (2 min)
3. Wait for build/startup (3-5 min)
4. Access application (1 min)

---

## Vulnerability & Remediation

### Q: Is this vulnerability real?
A: The vulnerability framework is based on real security concepts. For this training environment, we use a educational reference (CVE-2026-42533). The workflow is identical to real-world scenarios.

### Q: Why is NGINX 1.30.3 vulnerable?
A: This is used as a training vehicle. In the real world, always check:
- NIST National Vulnerability Database (NVD)
- Vendor security advisories
- Security scanners (Trivy, Snyk, etc.)

### Q: Do I have to update to 1.30.4?
A: For the training exercise, yes. In production, you'd:
1. Check for breaking changes
2. Test in staging environment
3. Plan deployment window
4. Have rollback plan ready

### Q: How do I know if the fix worked?
A: Multiple ways to verify:
```bash
# 1. Check the API
curl http://localhost:8080/api/status | jq '.vulnerability.status'
# Should return: "remediated"

# 2. Scan the image
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image ninjapaws-dojo:remediated

# 3. Check in Defender for Cloud (if deployed to Azure)
# Should show: No critical vulnerabilities
```

---

## Docker & Containers

### Q: What if port 8080 is already in use?
A: Change the port in `docker-compose.yml`:
```yaml
ports:
  - "9999:80"  # Use 9999 instead of 8080
```
Then access: http://localhost:9999

### Q: How do I view Docker logs?
A: 
```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f dojo

# Last 50 lines
docker-compose logs --tail=50
```

### Q: Can I build the image manually?
A: Yes:
```bash
docker build -t ninjapaws-dojo:custom .
docker run -p 8080:80 ninjapaws-dojo:custom
```

### Q: How do I clean up Docker?
A: 
```bash
# Stop containers
docker-compose down

# Remove containers and volumes
docker-compose down -v

# Remove unused images
docker image prune

# Full cleanup (warning: removes all unused)
docker system prune -a
```

---

## GitHub & Actions

### Q: What are these GitHub Actions workflows?
A: Three automated workflows:
1. **Detect Vulnerability**: Scans for security issues (on push/PR)
2. **Deploy**: Builds and deploys to Azure (on merge to main)
3. **Validate Remediation**: Tests the fix (on PR to main)

### Q: Why are my workflows failing?
A: Common causes:
- Secrets not configured (add AZURE_* secrets)
- Docker build failures (check Dockerfile syntax)
- ACR not set up (check Azure resources)
- Rate limiting (wait a few minutes, retry)

### Q: How do I run workflows manually?
A: On GitHub:
1. Go to "Actions" tab
2. Select workflow
3. Click "Run workflow" button
4. Choose branch
5. Click "Run"

### Q: Can I use these workflows without Azure?
A: Yes! 
- Scanning parts work locally with Trivy
- Deployment needs Azure (or modify for other cloud)
- Workflows are examples - modify as needed

---

## Azure & Cloud Deployment

### Q: How much will this cost?
A: Estimate for training:
- Azure Container Registry (Basic): ~$5/month
- App Service (B1): ~$15/month
- **Total: ~$20/month** (or free tier if eligible)

### Q: Can I use the free tier?
A: Partially:
- Azure free account has $200 credit (30 days)
- Container Registry needs paid tier
- App Service can use free tier initially

### Q: How do I avoid running costs?
A: 
- Delete resource group when not using: `az group delete --name ninjapaws-dojo`
- Use free tier while available
- Set up budget alerts in Azure Portal
- Monitor usage in Cost Management

### Q: What if deployment fails?
A: Check these:
```bash
# 1. Verify authentication
az account show

# 2. Check resource group
az group list

# 3. Check App Service logs
az webapp log tail --resource-group ninjapaws-dojo --name ninjapaws-dojo-app

# 4. Restart service
az webapp restart --resource-group ninjapaws-dojo --name ninjapaws-dojo-app
```

### Q: How do I deploy to different cloud?
A: This is possible but requires:
- Modifying Bicep templates
- Creating new deployment workflows
- Adjusting container configuration
- Security considerations for each platform

---

## Microsoft Defender & Security

### Q: How do I enable Defender for Cloud?
A: 
1. Go to Azure Portal
2. Search "Defender for Cloud"
3. Select subscription
4. Check "Container registries" is enabled
5. Wait for scanning to begin (~24 hours)

### Q: Why don't I see vulnerabilities in Defender?
A: Possible reasons:
- Defender not enabled yet
- Scanning hasn't completed
- ACR is not connected
- Image not pushed to ACR

### Q: How often does Defender scan?
A: By default:
- Scans on image push
- Continuous monitoring enabled
- Re-scans periodically (usually daily)
- You can trigger manual scans

### Q: What do severity levels mean?
A: In Defender for Cloud:
- **CRITICAL**: Immediate action required
- **HIGH**: Should fix soon
- **MEDIUM**: Address in normal cycle
- **LOW**: Monitor, fix when convenient

---

## Training & Learning

### Q: Which exercise should I start with?
A: Follow this path:
1. **Level 1:** Run locally & understand vulnerability (30 min)
2. **Level 2:** Create remediation PR & validate (1-2 hours)
3. **Level 3:** Deploy to Azure & monitor (2-4 hours)

See [HANDS_ON_LAB.md](docs/HANDS_ON_LAB.md) for details.

### Q: Can I skip to Azure deployment?
A: Possible, but you'll miss:
- Understanding vulnerability detection
- Learning remediation workflow
- Hands-on validation skills

Recommended: Do Levels 1-2 locally first.

### Q: How long is the full training?
A: Depends on your experience:
- **Beginners:** 4-8 hours across 2-3 days
- **Intermediate:** 2-4 hours in one session
- **Advanced:** 1-2 hours (or skip/skim sections)

### Q: Can I use this for a workshop?
A: Absolutely! Suggested format:
- **30 min intro:** Overview of cloud security workflow
- **45 min demo:** Show detection → remediation → validation
- **1-2 hours hands-on:** Participants follow along
- **30 min wrap-up:** Q&A and next steps

See [README.md](README.md) under "Use Cases" for workshop guides.

---

## Troubleshooting

### Q: "Permission denied" when running scripts?
A: Make scripts executable:
```bash
chmod +x scripts/deploy.sh
chmod +x entrypoint.sh
```

### Q: "docker: command not found"
A: Docker isn't installed or not in PATH:
- Install Docker: https://docs.docker.com/get-docker/
- Restart terminal after installation
- Test: `docker --version`

### Q: Application starts but endpoints don't respond
A: 
```bash
# 1. Check if container is running
docker-compose ps

# 2. Check logs
docker-compose logs

# 3. Test directly in container
docker-compose exec dojo curl localhost:3000/health

# 4. Check port binding
netstat -tln | grep 8080
```

### Q: "Address already in use" error
A: Another process is using the port:
```bash
# Find process using port
lsof -i :8080

# Kill it (replace PID with actual number)
kill -9 <PID>

# Or change port in docker-compose.yml
```

### Q: Image won't build
A: Check these:
1. Docker daemon is running
2. Dockerfile syntax is correct
3. Enough disk space
4. No network issues

```bash
docker build --no-cache -t ninjapaws-dojo:test .
```

---

## Advanced Questions

### Q: Can I modify the vulnerability?
A: Yes! This is educational:
1. Choose a real CVE
2. Update Dockerfile/dependencies
3. Modify application code if needed
4. Test extensively
5. Update documentation

### Q: How do I add more endpoints?
A: Edit `app.js`:
```javascript
app.get('/new-endpoint', (req, res) => {
  res.json({ message: 'Your content here' });
});
```

### Q: Can I integrate with my own security tools?
A: Possible! Options:
- Modify GitHub Actions workflows
- Use webhook integrations
- Deploy to your cloud platform
- Integrate with your scanning tools

### Q: How do I use this in a CI/CD pipeline?
A: The workflows are examples:
- Customize for your needs
- Add your own steps
- Integrate with your tools
- Adjust triggers as needed

---

## Getting Help

### Resources

- 📖 [README.md](README.md) - Complete overview
- 🚀 [QUICK_START.md](docs/QUICK_START.md) - Get running fast
- 📚 [HANDS_ON_LAB.md](docs/HANDS_ON_LAB.md) - Training exercises
- 🛡️ [VULNERABILITY_GUIDE.md](docs/VULNERABILITY_GUIDE.md) - Deep dive
- ☁️ [AZURE_DEPLOYMENT.md](docs/AZURE_DEPLOYMENT.md) - Azure guide
- 🤝 [CONTRIBUTING.md](CONTRIBUTING.md) - How to contribute

### Contact

- 💬 GitHub Issues - Ask questions
- 🗣️ GitHub Discussions - Start conversations
- 🐛 Bug reports - Report issues
- 🔐 Security - See [SECURITY.md](SECURITY.md)

---

## FAQ Updates

Is your question not answered here? 
- Open a GitHub Discussion
- Submit as an Issue with "question" label
- We'll add it to this FAQ!

---

**Happy learning! 🥷🛡🐾**
