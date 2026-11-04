# Diagnostics: read-only checks for Salesforce Voice calls

Collect facts before proposing a fix. Every check is read-only. Query by record Id and print **flags, counts and codes** only, never numbers, names, transcript or summary text (`security.md`).

## The five facts about one call
| Fact | Query (sf data query -o <alias>) | Print |
|---|---|---|
| Call record | `SELECT CallType, CallDisposition, DisconnectReason, CallDurationInSeconds, CallAcceptDateTime, CallEndDateTime, VendorType, ConversationIdentifier FROM VoiceCall WHERE Id = '<id>'` | type, disposition, reason, seconds, accepted yes/no |
| Recording | `SELECT DurationInSeconds FROM VoiceCallRecording WHERE VoiceCallId = '<id>'` | count, total seconds |
| Agent work | `SELECT Status, AcceptDateTime, CloseDateTime FROM AgentWork WHERE WorkItemId = '<id>'` | status, accepted yes/no |
| Transcript | REST, not SOQL (below) | entry count |
| Flow versions | Tooling: `SELECT DeveloperName, ActiveVersion.VersionNumber, LatestVersion.VersionNumber, LastModifiedDate FROM FlowDefinition WHERE DeveloperName LIKE 'IVR_<KEY>_%'` | versions, last change |

**Transcript entries:** SOQL on `ConversationEntry` returns nothing for Native Voice. Count entries with the Connect REST API and print the count only:
```
sf api request rest "/services/data/v66.0/connect/conversation/<ConversationIdentifier>/entries" -o <alias>
```
**Org-level switches:** recording and transcription are org settings (`ThunderbirdVoiceSettings`: `enableCallRecording`, `enableCallTranscription`). Retrieve them read-only through the `Settings` container, member `ThunderbirdVoice`, with a package at API **68.0** (lower versions return nothing).

## Symptom → checks → likely cause
| Symptom | Check | Likely cause / next step |
|---|---|---|
| Every inbound call ends in 1–3 s, `DisconnectReason` system issue, before the first prompt | Several calls in the window; FlowDefinition `LastModifiedDate`; Setup Audit Trail (Action, Section only) for the window; Salesforce status page | Platform or telephony-setting change, not flow logic, when no flow changed before the first failure. Don't edit flows to "fix" it; escalate. Recovery without a flow change confirms it |
| Call connects to an agent, Conversation panel shows only "call started / ended" | Transcript entry count = 0; `CallType` | `Outbound` click-to-dial: no flow runs, the platform doesn't transcribe it (Salesforce case). Inbound: was transcription switched back on before Route Work? |
| No recording | `CallAcceptDateTime` null? | IVR-only calls are never recorded; recording starts when an agent joins |
| Recording exists, talk time 0:00:00 | Recording seconds vs talk-time field; scheduled path ran? (Setup → Paused and Waiting Interviews) | Recording saved after the last call update; the scheduled-path talk-time flow fills it a few minutes after `CallEndDateTime`. Backfill old calls with anonymous Apex calling the same service (file saved without BOM) |
| No AI summary | Accepted? Transcript count? Flow on async path? | No agent, no transcript (gate stopped it, correct), or the summary flow isn't on the async-after-commit path |
| Callback dial ends at 0 s, system issue | `CallType`, `CallDurationInSeconds`, `DisconnectReason` of the outbound call; preview vs auto-dial | Auto-dial path failing for that agent/number; a manual preview dial connects. Retest with a number the agent never handled; raise a case. A VoiceCall existing is not proof the dial worked |
| Callbacks never reach the callback queue | Route Work fault in the offer flow; queue Supported Objects | Contact Request missing from the callback queue's supported objects |
| Agent never rings | AgentWork rows? Agent presence, permission set licence, queue membership | Agent setup (traps.md #4, #5) or a queue passed in a variable |

## Rules for diagnosing
- State the cause and the proposed fix, then wait for approval before changing anything.
- One failing call is an anecdote: check at least three calls across the window and one that worked.
- Compare against the last known good call (same number, same path) before blaming a recent change.
- Debug logs on the integration user hold caller data: enable only for the test, delete afterwards, never paste them.
