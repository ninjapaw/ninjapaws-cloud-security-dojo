// Prints the GitHub Actions OIDC federated-credential subject, computed by the
// vendored copy of pawprint's github-oidc-subject.mjs so every repo in the org
// agrees on this string byte-for-byte instead of hand-interpolating it in bash.
//
//   node scripts/compute-oidc-subject.mjs <owner-login> <owner-id> <repo-name> <repo-id> <environment>
import { githubEnvironmentSubject } from "../vendor/pawprint/scripts/github-oidc-subject.mjs";

const [ownerLogin, ownerId, repoName, repoId, environment] =
  process.argv.slice(2);

process.stdout.write(
  githubEnvironmentSubject(
    {
      owner: { login: ownerLogin, id: Number(ownerId) },
      name: repoName,
      id: Number(repoId),
    },
    environment,
  ),
);
