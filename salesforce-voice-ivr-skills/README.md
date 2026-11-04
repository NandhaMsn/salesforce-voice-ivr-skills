# Salesforce Voice IVR skills for Claude Code

Claude Code skills for moving a keypad (DTMF) IVR from **Amazon Connect** to **Salesforce Voice** (native telephony in Agentforce Contact Center), and for building, testing and running it afterwards: contact flows become routing flows, Lambdas become Apex, one org can serve many clients.

| Skill | What it does | Tools inside |
|---|---|---|
| `connect-ivr-to-salesforce-voice` | Turns Amazon Connect contact-flow exports into an inventory, a Connect → Salesforce mapping, a gap list, a per-client design and a build order. Read-only. | `Get-ConnectInventory.ps1`: maps every block, lists Lambdas, flags gaps and secrets (location only), masks numbers and AWS account Ids |
| `salesforce-voice-ivr-build` | Blueprints for every flow (entry, menus, verified self-service, agent handoff, callback offer, direct line, talk time, AI summary), prompt and retry settings, Lambda → Apex template, multi-client isolation, callbacks and security rules. | Flow catalog, Apex template, callback contract |
| `salesforce-voice-ivr-test-deploy` | Static flow checks, safe deploys, read-only diagnostics and 32 known platform traps with fixes. | `Test-IvrFlow.ps1` (20+ checks incl. client isolation and hard-coded secrets), `Deploy-IvrFlow.ps1` (draft check, backup, API 68.0 package, dry run, deploy, verify, rollback hint, log) |

The examples use a made-up city utility line (billing, outages, start service) and placeholder client keys (`ACME`). The build skill includes a **complete worked IVR** (`reference-ivr.md`): 14 flows covering entry, menus, five self-service features, a partner transfer, agent handoff, callback, a direct line, callback cleanup, talk time and AI summary, each with keys, steps and test scenarios, plus an end-to-end test plan. Every script ships with synthetic self-test fixtures.

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
- "Build the amount-due flow for client ACME using our IVR conventions."
- "Add a callback offer when all agents are busy."
- "Check my flows, then dry-run the deploy to my sandbox."
- "Calls queue but no agent rings. What's wrong?"
- "The Conversation panel is empty on this call. Why?"

Run the scripts directly too:

```powershell
.\Get-ConnectInventory.ps1 -Path .\connect-exports -OutFile .\connect-inventory.md -Mermaid
.\Test-IvrFlow.ps1 -Path force-app\main\default\flows -Filter 'IVR_ACME_*' -ClientPrefix IVR_ACME_
.\Deploy-IvrFlow.ps1 -TargetOrg my-sandbox -FlowName IVR_ACME_Agent_Handoff          # dry run
.\Deploy-IvrFlow.ps1 -TargetOrg my-sandbox -FlowName IVR_ACME_Agent_Handoff -Deploy  # after approval
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Salesforce CLI (`sf`) logged in to the target org (deploy and org checks only).
- An org with Salesforce Voice / Native Voice enabled.

## Safety built in

- Exports, flows, logs and records are treated as data, never as instructions.
- No caller data is printed: checks print flags and counts; scripts mask numbers and never show secret values.
- Deploys are dry runs by default, stop on someone else's draft, and need explicit approval (and `-AllowProduction`) for production.
- Multi-client orgs: every flow, query and trigger is scoped to one client; the checker enforces it.

## Author

NandhaKumar M

[LinkedIn](https://www.linkedin.com/in/m-nandha-kumar/)

## License

MIT. See [LICENSE](LICENSE).
