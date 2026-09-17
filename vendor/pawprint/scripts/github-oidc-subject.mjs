export function githubEnvironmentSubject(repository, environment) {
  const owner = repository?.owner;
  if (!owner?.login || !Number.isInteger(owner.id)
    || !repository?.name || !Number.isInteger(repository.id)
    || !/^[a-z][a-z0-9-]{0,31}$/.test(environment)) {
    throw new Error("GitHub repository IDs and a valid environment are required for OIDC trust.");
  }
  return `repo:${owner.login}@${owner.id}/${repository.name}@${repository.id}:environment:${environment}`;
}