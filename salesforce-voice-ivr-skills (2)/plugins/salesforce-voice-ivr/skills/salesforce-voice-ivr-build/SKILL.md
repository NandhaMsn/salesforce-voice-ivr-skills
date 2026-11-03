---
name: salesforce-voice-ivr-build
description: Build or change keypad (DTMF) IVR routing flows and their Apex for Salesforce Voice / Native Voice (Agentforce Contact Center), following proven conventions for prompts, retries, subflow contracts, Lambda-to-Apex services, routing, agent setup, transcription and post-call AI summary. TRIGGER when the user asks to create, edit, fix or extend a Salesforce Voice IVR routing flow, menu, prompt, Route Work, external transfer, business-hours check, IVR Apex invocable, or the post-call summary / talk-time automation. DO NOT TRIGGER for planning a migration from Connect (use connect-ivr-to-salesforce-voice) or for test/deploy routines (use salesforce-voice-ivr-test-deploy).
---

# Build Salesforce Voice IVR flows

## Before changing anything
1. Ask which flows are in scope. Edit only the IVR's own flows (one prefix, e.g. `IVR_<Line>_*`). Shared flows used by other lines need explicit approval.
2. For a bug: state the cause and the proposed fix, and wait for approval before editing.
3. Query `FlowDefinition` (Tooling API) and confirm ActiveVersion = LatestVersion. If a newer Draft exists, retrieve it first; deploying would overwrite it.
4. Retrieve the current flow from the org; never build on a stale local copy.
5. Back up the file you are about to replace.

## Flow conventions
See `references/conventions.md` for exact prompt settings. In short:
- Routing Flows, API 68.0, input `recordId` (the VoiceCall Id).
- Entry flow → language main menus → feature subflows → one queue-transfer flow.
- Every feature subflow returns `nextStep` = `END` | `MAIN_MENU` | `AGENT`. Menus read only that.
- One `playPromptAsyncAction` per question; input collected on the same element.
- `requireResponseRetry=false`; retries handled with counters in the flow.
- Accept all keys; formula `NOT(ISBLANK({!Prompt.dtmfInput}))` separates wrong key from no input.
- `#` repeats a menu; repeated `#` or `9` goes to an agent.
- Read-backs of digits via formulas (no say-as). SSML: only `<break>` and `<phoneme>`.
- Write IVR details to VoiceCall (language, `code|label` menu selection, feature status/error). Every Update Records has a fault path that continues the call.
- Every Apex action, Route Work and external transfer has a fault path: Apex/transfer fault → agent; routing fault → error message → end.

## Lambda → Apex
- One `@InvocableMethod` class per Lambda / operation family, label `IVR: <Action>`, `callout=true` when it calls HTTP.
- Return a status/error code (`NO_ERROR` on success) plus the text to speak, never throw to the flow.
- No caller data in logs. Credentials via Named/External Credentials, never plaintext secrets in custom metadata.
- Runs as the Platform Integration User: grant class access through a permission set.
- Match customers on more than one factor (e.g. account number + service ZIP code) and require exactly one match.
- Template: `references/apex-invocable-template.md`.

## Routing and agents
- Queue transfer: save details → hours check (fail open on error) → closed message or hold message → `disableRecAndTranscription` with both false (transcription on) → `routeWork` QueueBased on `sfdc_phone` with a **fixed** queue per language.
- Agent rings only with: Salesforce Voice PSL, Native Voice Contact Center agent permission set, queue membership, presence status containing `sfdc_phone`, fresh Omni login.
- Do not use `inQueueFlowAction` or flow Media prompts for hold audio; default queue music is reliable.

## Recording, transcript, post-call
- Entry flow: transcription off. Queue transfer: transcription on just before Route Work, so only the agent conversation is transcribed.
- AI summary flow: after-save on VoiceCall update, require `CallAcceptDateTime` not null, run on the **AsyncAfterCommit** path, get transcript, stop if blank ("has transcript?" gate), call the prompt template, save only a real summary.
- Talk time on Native Voice: `VoiceCall.CallRecordingId` is empty; sum `VoiceCallRecording.DurationInSeconds` from a scheduled path a few minutes after `CallEndDateTime` (recording rows can't fire triggers).

## Rules
| Rule | Why |
|---|---|
| Explain cause + proposal first, change after approval | Shared contact-center orgs; caller experience is the business's call |
| Patch flow XML with scripts, keep elements of one type grouped, formulas before `interviewLabel` | Flow Builder metadata order errors on deploy |
| Synthetic data only (e.g. +1 202-555-0100); never print customer data or summary text | Personal data |
| Keep queue IDs and org-specific constants in one place where possible | They change per org |

## Reference files
| File | When to read |
|---|---|
| `references/conventions.md` | Writing any prompt, menu or free-digit entry |
| `references/apex-invocable-template.md` | Writing an IVR Apex service |
