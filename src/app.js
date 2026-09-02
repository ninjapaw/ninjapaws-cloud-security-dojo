#!/usr/bin/env node

const express = require('express');
const os = require('os');
const fs = require('fs');

const app = express();
const PORT = Number(process.env.PORT) || 3000;
const DEFAULT_NGINX_VERSION = '1.30.3';
const DEFAULT_VULNERABILITY_STATUS = 'vulnerable';
const CVE_ID = 'CVE-2026-42533';
const VULNERABILITY_DESCRIPTION = 'NGINX map directive and regex matching heap buffer overflow';
const ADVISORY_URL = 'https://my.f5.com/manage/s/article/K000162097';
const AFFECTED_VERSIONS = 'NGINX Open Source 1.30.0-1.30.3';
const FIXED_VERSION = '1.30.4';

function getRuntimeVerification() {
  try {
    return JSON.parse(fs.readFileSync('/run/ninja-paws-runtime.json', 'utf8'));
  } catch (_error) {
    return {
      nginx_binary_version: null,
      nginx_package_version: null
    };
  }
}

function getVulnerabilityStatus(runtimeVerification) {
  if (runtimeVerification.vulnerability_detected === true) return 'vulnerable';
  if (runtimeVerification.scenario_config_state === 'remediated') return 'remediated';
  return 'not_detected';
}

function getRuntimeStatus() {
  const runtimeVerification = getRuntimeVerification();
  return {
    nginxVersion: process.env.NGINX_VERSION || DEFAULT_NGINX_VERSION,
    vulnerabilityStatus: getVulnerabilityStatus(runtimeVerification),
    vulnerabilityDetected: runtimeVerification.vulnerability_detected === true,
    defenderEnabled: isEnabled('DEFENDER_ENABLED'),
    detectionReason: runtimeVerification.detection_reason || 'Runtime detection evidence is unavailable.'
  };
}

// ARM emits string(bool) as "True"/"False", so compare case-insensitively.
function isEnabled(name) {
  return String(process.env[name] ?? '').trim().toLowerCase() === 'true';
}

function isTier(name, tier) {
  return String(process.env[name] ?? '').trim().toLowerCase() === tier.toLowerCase();
}

// The container holds no Azure credentials, so this reports deployment-time configuration only.
function getDefenderMonitoring() {
  return {
    source: 'deployment-configuration',
    authoritative_source: 'Microsoft Defender for Cloud (Environment settings)',
    note: 'These flags report what the deployment requested, not a live query of Azure plan state.',
    plans: {
      defender_for_app_service: process.env.DEFENDER_APPSERVICES_TIER || 'unknown',
      defender_for_containers: process.env.DEFENDER_CONTAINERS_TIER || 'unknown',
      defender_cspm: process.env.DEFENDER_CSPM_TIER || 'unknown',
      defender_for_resource_manager: process.env.DEFENDER_ARM_TIER || 'unknown'
    },
    monitoring: {
      defender_dashboard_flag: isEnabled('DEFENDER_ENABLED'),
      app_service_threat_protection: isTier('DEFENDER_APPSERVICES_TIER', 'Standard'),
      resource_manager_threat_detection: isTier('DEFENDER_ARM_TIER', 'Standard'),
      container_registry_vulnerability_assessment: isEnabled('DEFENDER_REGISTRY_ASSESSMENT'),
      cspm_serverless_protection: isEnabled('DEFENDER_SERVERLESS_PROTECTION'),
      cspm_serverless_containers: isEnabled('DEFENDER_SERVERLESS_CONTAINERS'),
      devops_connector_requested: isEnabled('DEFENDER_DEVOPS_CONNECTOR'),
      github_advanced_security_expected: isEnabled('GITHUB_ADVANCED_SECURITY')
    }
  };
}

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    environment: 'training'
  });
});

app.get('/evidence', (req, res) => {
  try {
    res.json({
      expected_cve: CVE_ID,
      expected_nginx_version: DEFAULT_NGINX_VERSION,
      nginx_version_output: fs.readFileSync('/opt/nginx-version.txt', 'utf8').trim(),
      package_version: fs.readFileSync('/opt/nginx-package-version.txt', 'utf8').trim(),
      installed_packages: fs.readFileSync('/opt/nginx-installed-packages.txt', 'utf8').trim()
    });
  } catch (error) {
    console.error('Unable to read build-time NGINX evidence:', error);
    res.status(500).json({ error: 'Build-time NGINX evidence is unavailable.' });
  }
});

// API status endpoint
app.get('/api/status', (req, res) => {
  const { nginxVersion, vulnerabilityStatus } = getRuntimeStatus();
  const runtimeVerification = getRuntimeVerification();
  const vulnerabilityDetected = runtimeVerification.vulnerability_detected === true;

  res.json({
    environment: 'Ninja Paws Cloud Security Dojo',
    status: 'running',
    nginx_version: nginxVersion,
    vulnerability: {
      cve_id: CVE_ID,
      status: vulnerabilityStatus,
      detected: vulnerabilityDetected,
      description: VULNERABILITY_DESCRIPTION,
      advisory_url: ADVISORY_URL,
      affected_versions: AFFECTED_VERSIONS,
      fixed_version: FIXED_VERSION
    },
    runtime_verification: runtimeVerification,
    defender_monitoring: getDefenderMonitoring(),
    host: os.hostname(),
    platform: os.platform(),
    arch: os.arch(),
    uptime: process.uptime(),
    timestamp: new Date().toISOString()
  });
});

// Home endpoint
app.get('/', (req, res) => {
  const { nginxVersion, vulnerabilityStatus, defenderEnabled } = getRuntimeStatus();
  const defenderMonitoring = getDefenderMonitoring();
  const monitoringRow = (label, enabled) =>
    `<li><code>${label}</code> - ${enabled ? '✅ true' : '⚪ false'}</li>`;

  const html = `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>🥷 Ninja Paws Cloud Security Dojo</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
      background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
      color: #333;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }

    .container {
      background: white;
      border-radius: 12px;
      box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
      max-width: 800px;
      width: 100%;
      padding: 60px 40px;
      text-align: center;
    }

    .header {
      margin-bottom: 40px;
    }

    .logo {
      font-size: 64px;
      margin-bottom: 20px;
    }

    h1 {
      font-size: 36px;
      color: #1e3c72;
      margin-bottom: 10px;
      font-weight: bold;
    }

    .tagline {
      font-size: 18px;
      color: #666;
      font-style: italic;
      margin-bottom: 30px;
    }

    .status-section {
      background: #f8f9fa;
      border-radius: 8px;
      padding: 30px;
      margin: 30px 0;
      border-left: 4px solid #1e3c72;
    }

    .status-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      margin-top: 20px;
      text-align: left;
    }

    .status-item {
      background: white;
      padding: 15px;
      border-radius: 6px;
      border: 1px solid #e0e0e0;
    }

    .status-label {
      font-weight: 600;
      color: #1e3c72;
      font-size: 14px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 8px;
    }

    .status-value {
      font-size: 18px;
      color: #333;
      font-family: 'Courier New', monospace;
    }

    .vulnerability-alert {
      background: #fff3cd;
      border: 2px solid #ffc107;
      border-radius: 6px;
      padding: 20px;
      margin: 20px 0;
      text-align: left;
    }

    .vulnerability-alert.vulnerable {
      background: #f8d7da;
      border-color: #f5c6cb;
    }

    .vulnerability-alert.remediated {
      background: #d4edda;
      border-color: #c3e6cb;
    }

    .alert-title {
      font-weight: 700;
      font-size: 16px;
      margin-bottom: 10px;
    }

    .vulnerable .alert-title {
      color: #721c24;
    }

    .remediated .alert-title {
      color: #155724;
    }

    .alert-text {
      font-size: 14px;
      line-height: 1.5;
    }

    .vulnerable .alert-text {
      color: #721c24;
    }

    .remediated .alert-text {
      color: #155724;
    }

    .defender-badge {
      display: inline-block;
      background: #007bff;
      color: white;
      padding: 8px 16px;
      border-radius: 20px;
      font-size: 13px;
      font-weight: 600;
      margin-top: 15px;
    }

    .disclaimer {
      background: #f0f0f0;
      border: 1px solid #ddd;
      border-radius: 6px;
      padding: 20px;
      margin-top: 30px;
      font-size: 13px;
      line-height: 1.6;
      color: #666;
      text-align: left;
    }

    .disclaimer strong {
      display: block;
      color: #1e3c72;
      margin-bottom: 10px;
    }

    .endpoints {
      margin-top: 30px;
      text-align: left;
    }

    .endpoints h3 {
      color: #1e3c72;
      margin-bottom: 15px;
    }

    .endpoint-list {
      list-style: none;
      font-size: 14px;
      font-family: 'Courier New', monospace;
    }

    .endpoint-list li {
      padding: 8px 0;
      color: #666;
    }

    .endpoint-list code {
      background: #f5f5f5;
      padding: 2px 6px;
      border-radius: 3px;
      color: #1e3c72;
    }

    .footer {
      margin-top: 40px;
      padding-top: 30px;
      border-top: 1px solid #eee;
      font-size: 13px;
      color: #999;
    }

    @media (max-width: 600px) {
      .status-grid {
        grid-template-columns: 1fr;
      }

      h1 {
        font-size: 28px;
      }

      .container {
        padding: 40px 20px;
      }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="logo">🥷🛡🐾</div>
      <h1>Ninja Paws Cloud Security Dojo</h1>
      <p class="tagline">Master the art of cloud security one vulnerability at a time</p>
    </div>

    <div class="status-section">
      <strong>Training Environment Status</strong>
      <div class="status-grid">
        <div class="status-item">
          <div class="status-label">NGINX Version</div>
          <div class="status-value">${nginxVersion}</div>
        </div>
        <div class="status-item">
          <div class="status-label">CVE Identifier</div>
          <div class="status-value">${CVE_ID}</div>
        </div>
        <div class="status-item">
          <div class="status-label">Vulnerability Status</div>
          <div class="status-value" style="text-transform: uppercase; font-weight: 600; color: ${vulnerabilityStatus === 'vulnerable' ? '#dc3545' : '#28a745'};">
            ${vulnerabilityStatus}
          </div>
        </div>
        <div class="status-item">
          <div class="status-label">Defender Enabled</div>
          <div class="status-value">${defenderEnabled ? '✅ Yes' : '⏳ Monitoring'}</div>
        </div>
      </div>
    </div>

    <div class="vulnerability-alert ${vulnerabilityStatus}">
      <div class="alert-title">
        ${vulnerabilityStatus === 'vulnerable' ? '⚠️ Vulnerable Version Detected' : '✅ Vulnerability Remediated'}
      </div>
      <div class="alert-text">
        <strong>${CVE_ID}:</strong> ${VULNERABILITY_DESCRIPTION}
        <br>
        ${vulnerabilityStatus === 'vulnerable'
          ? 'This training environment intentionally contains a vulnerable software version (NGINX 1.30.3) for educational detection and remediation demonstrations.'
          : 'This version has been patched. NGINX is now at version 1.30.4 or later with the vulnerability remediated.'
        }
      </div>
      ${defenderEnabled ? '<span class="defender-badge">🛡 Microsoft Defender Monitoring Active</span>' : ''}
    </div>

    <div class="endpoints">
      <h3>Defender for Cloud Monitoring</h3>
      <ul class="endpoint-list">
        ${monitoringRow('app_service_threat_protection', defenderMonitoring.monitoring.app_service_threat_protection)}
        ${monitoringRow('resource_manager_threat_detection', defenderMonitoring.monitoring.resource_manager_threat_detection)}
        ${monitoringRow('container_registry_vulnerability_assessment', defenderMonitoring.monitoring.container_registry_vulnerability_assessment)}
        ${monitoringRow('cspm_serverless_protection', defenderMonitoring.monitoring.cspm_serverless_protection)}
        ${monitoringRow('cspm_serverless_containers', defenderMonitoring.monitoring.cspm_serverless_containers)}
        ${monitoringRow('devops_connector_requested', defenderMonitoring.monitoring.devops_connector_requested)}
        ${monitoringRow('github_advanced_security_expected', defenderMonitoring.monitoring.github_advanced_security_expected)}
        <li><strong>Declared configuration:</strong> Defender for Cloud remains the authoritative source; see <code>defender_monitoring</code> in <code>/api/status</code>.</li>
      </ul>
    </div>

    <div class="endpoints">
      <h3>Available Endpoints</h3>
      <ul class="endpoint-list">
        <li><code>/</code> - Human-readable training dashboard</li>
        <li><code>/health</code> - JSON health probe used by App Service and rollout checks</li>
        <li><code>/evidence</code> - JSON build-time NGINX version and package evidence</li>
        <li><code>/api/status</code> - JSON CVE metadata and runtime package/config evidence</li>
        <li><strong>Internal NGINX evidence:</strong> inspect the <code>map</code> configuration through <code>runtime_verification.map_regex_enabled</code> in <code>/api/status</code>.</li>
      </ul>
    </div>

    <div class="disclaimer">
      <strong>📋 Educational Disclaimer</strong>
      <div>
        This environment is part of the Ninja Paws Cloud Security Dojo training program. It intentionally contains a vulnerable software version for educational detection and remediation demonstrations. This repository contains no customer data, production credentials, or business-sensitive information. All values are examples and placeholders only.
      </div>
      <div style="margin-top: 10px;">
        This is an independent community project, not a Microsoft product, assessment, endorsement, or official security guidance. Microsoft employees may contribute in an individual or community capacity. Use at your own risk and validate all demo behavior before using it in any environment. See DISCLAIMER.md in the repository.
      </div>
      <div style="margin-top: 10px;">
        <strong>🎯 Learning Objectives:</strong> Vulnerability detection, remediation, secure supply chains, container security, and Microsoft Defender for Cloud capabilities.
      </div>
    </div>

    <div class="footer">
      <p>🐾 Ninja Paws | Cloud Security Training Environment</p>
      <p>For Conferences • Workshops • Community Events • Training Sessions</p>
    </div>
  </div>
</body>
</html>
  `;

  res.send(html);
});

// Start server
app.listen(PORT, () => {
  console.log(`🥷 Ninja Paws Cloud Security Dojo`);
  console.log(`🏯 Server running on port ${PORT}`);
  console.log(`⚔ Remediation Mission: Detect and fix CVE-2026-42533`);
  console.log(`✅ Endpoints: / | /health | /evidence | /api/status`);
});

module.exports = app;
