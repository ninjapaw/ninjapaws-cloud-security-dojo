import { DefaultAzureCredential } from "@azure/identity";
import { SecretClient } from "@azure/keyvault-secrets";

const TARGET_LOGIN_USERNAME_SECRET = "sql-sa-login-username";
const TARGET_LOGIN_PASSWORD_SECRET = "sql-sa-login-password";

let secretClient;

function getSecretClient() {
  const vaultUrl = process.env.KEY_VAULT_URI;
  if (!vaultUrl) {
    throw new Error(
      "KEY_VAULT_URI must be configured to synchronize SQL administrator credentials.",
    );
  }
  if (!secretClient) {
    secretClient = new SecretClient(vaultUrl, new DefaultAzureCredential());
  }
  return secretClient;
}

export function isAdminSecretsConfigured() {
  return Boolean(process.env.KEY_VAULT_URI);
}

export function requireAdminSecretsConfigured() {
  if (!isAdminSecretsConfigured()) {
    throw new Error(
      "KEY_VAULT_URI must be configured before changing the built-in administrator credentials.",
    );
  }
}

export async function storeTargetAdminUsername(username) {
  await getSecretClient().setSecret(TARGET_LOGIN_USERNAME_SECRET, username);
}

export async function storeTargetAdminPassword(password) {
  const secret = await getSecretClient().setSecret(
    TARGET_LOGIN_PASSWORD_SECRET,
    password,
  );
  return secret.value ?? password;
}

export async function getTargetAdminPassword() {
  const secret = await getSecretClient().getSecret(
    TARGET_LOGIN_PASSWORD_SECRET,
  );
  return secret.value ?? null;
}

export async function verifyTargetAdminPassword(password) {
  const storedPassword = await getTargetAdminPassword();
  return storedPassword === password;
}
