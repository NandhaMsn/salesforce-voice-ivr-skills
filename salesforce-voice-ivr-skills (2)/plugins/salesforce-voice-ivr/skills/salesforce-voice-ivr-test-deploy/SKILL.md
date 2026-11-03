---
name: salesforce-voice-ivr-test-deploy
description: Test and deploy Salesforce Voice / Native Voice IVR routing flows and Apex safely - static flow-XML checks, a flow simulator with control runs, dry-run deploys at API 68.0, active-version verification, rollback, live-call verification and a log of every deploy; plus a table of known platform traps and fixes. TRIGGER when the user asks to test, verify, validate, deploy, activate, roll back or troubleshoot a Salesforce Voice IVR flow or call (no agent rings, input accepted on third try, deploy version errors, blank talk time, missing summary). DO NOT TRIGGER for migration planning (connect-ivr-to-salesforce-voice) or for designing new flow logic (salesforce-voice-ivr-build).
---

# Test and deploy a Salesforce Voice IVR

## Test layers (run in this order)
1. **Static checks on the flow XML** (script it; see `references/checks.md`): connectors resolve, no unreachable elements, every prompt has text in the flow's language, fault paths on Apex / Route Work / transfer / record updates, decisions test only keys the prompt accepts, no dead ends, referenced subflows exist and are active.
2. **Flow simulator**: interpret the XML, evaluate formulas, feed scripted key sequences (`X` = no input), mock Apex, routing and transfer. One scenario per path and per error branch.
3. **Control run**: run the same scenarios against the previous flow versions. They must fail exactly where the change was made; otherwise the tests can't catch faults.
4. **Apex tests** with `RunSpecifiedTests` for every class in the package.
5. **Live calls** inside business hours, one per path and language. Afterwards query VoiceCall, AgentWork and VoiceCallRecording by Id and print flags only (has recording, accepted, disposition), never caller data.

## Deploy routine (every change)
1. Tooling query: `SELECT DeveloperName, ActiveVersion.VersionNumber, LatestVersion.VersionNumber FROM FlowDefinition WHERE DeveloperName IN (...)`. Stop if active ≠ latest (someone has a draft).
2. Back up the files being replaced.
3. Build a metadata-dir package with `package.xml` version **68.0** (voice actions need 65–67+).
4. `sf project deploy start -o <alias> --metadata-dir <pkg> --dry-run` (add `--test-level RunSpecifiedTests --tests ...` when Apex is included). Check the JSON `status`; never assume success.
5. Deploy for real only after the user approves (always for shared flows and permissions).
6. Re-query FlowDefinition: new version active = latest.
7. `sf project retrieve start -m Flow:<name> --ignore-conflicts` to sync source.
8. Log the deploy: date, components, deploy Id, tests, result, rollback step.
9. **Rollback** = reactivate the previous version (Tooling PATCH `FlowDefinition` `{"Metadata":{"activeVersionNumber":N}}`) or redeploy the backup.

## Troubleshooting
Use `references/traps.md`. Collect facts first (VoiceCall disposition, `DisconnectReason`, AgentWork, flow interview errors, setup audit trail), state the cause, and propose a fix before changing anything.

## Rules
| Rule | Why |
|---|---|
| Dry-run before every deploy; check `status` in JSON output | Silent failures led to wrong conclusions |
| Never deploy over a Draft | It overwrites a teammate's work |
| Deploying a flow as Obsolete does not deactivate it | Deactivate via FlowDefinition |
| Synthetic test numbers only; print flags, not data | PII/PHI |
| Windows PowerShell 5.1: variable names are case-insensitive; anonymous Apex files without BOM; Spanish text files UTF-8 with BOM | Script traps seen in practice |

## Reference files
| File | When to read |
|---|---|
| `references/checks.md` | Writing the static checker or simulator |
| `references/traps.md` | Any failing deploy, call or post-call record |
