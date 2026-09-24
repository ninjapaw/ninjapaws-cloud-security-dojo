import {
  attackScenarios,
  sqlAttackRunner,
} from "../apps/pawton-manufacturing/src/lib/sqlAttackLab.mjs";

const args = process.argv.slice(2);
if (args.length === 1 && ["--list", "--audit"].includes(args[0])) {
  console.log(
    JSON.stringify(
      { mode: "audit", executesSql: false, scenarios: attackScenarios },
      null,
      2,
    ),
  );
} else if (
  args.length === 4 &&
  args[0] === "--run" &&
  args[2] === "--confirm" &&
  args[3] === "isolated-lab"
) {
  try {
    const result = await sqlAttackRunner.run(args[1]);
    console.log(JSON.stringify(result, null, 2));
    if (result.state === "blocked") process.exitCode = 2;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
} else {
  console.error(
    "Usage: node scripts/run-sql-attack-test.mjs --audit | --list | --run <scenario-id> --confirm isolated-lab",
  );
  process.exitCode = 2;
}
