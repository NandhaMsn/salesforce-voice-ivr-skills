# Salesforce Voice IVR skills for Claude Code

Claude Code skills for moving a keypad (DTMF) IVR from **Amazon Connect** to **Salesforce Voice** (native telephony in Agentforce Contact Center): contact flows become routing flows, Lambdas become Apex.

| Skill | What it does |
|---|---|
| `connect-ivr-to-salesforce-voice` | Reads Amazon Connect contact-flow exports and produces an inventory, a Connect → Salesforce mapping, a gap list and a build order. Read-only. |
| `salesforce-voice-ivr-build` | Conventions for building the IVR: prompt and retry settings, the subflow `nextStep` contract, Lambda → Apex invocables, routing, agent setup, transcription, AI summary and talk time. |
| `salesforce-voice-ivr-test-deploy` | Static flow checks, a simulator with control runs, a safe dry-run deploy routine at API 68.0, rollback, live-call checks and a table of known platform traps. |

## Install

In Claude Code:

```
/plugin marketplace add YOUR-GITHUB-USER/salesforce-voice-ivr-skills
/plugin install salesforce-voice-ivr@salesforce-voice-ivr-skills
```

Or copy the folders under `plugins/salesforce-voice-ivr/skills/` into `~/.claude/skills/` (all projects) or `.claude/skills/` (one project).

## Use

Ask in plain words. Claude picks the right skill:

- "Here are my Amazon Connect flow exports, plan the migration to Salesforce Voice."
- "Build the amount-due routing flow using our IVR conventions."
- "Deploy the queue transfer flow and verify it's active."
- "Calls queue but no agent rings. What's wrong?"

## Requirements

- Salesforce CLI (`sf`) logged in to the target org.
- An org with Salesforce Voice / Native Voice enabled.

## Notes

- The skills use synthetic test data only and never print caller data.
- They explain the cause and proposed fix before changing anything in an org.

## Author

NandhaKumar M

[LinkedIn](https://www.linkedin.com/in/m-nandha-kumar/)

## License

MIT. See [LICENSE](LICENSE).
