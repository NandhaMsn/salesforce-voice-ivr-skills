# Known traps and fixes (Salesforce Voice IVR)

| # | Symptom / error | Cause | Fix |
|---|---|---|---|
| 1 | Input accepted only on the 3rd entry; success prompt plays 3× | `requireResponseRetry=true` | Set false, `retryCount=0`, retry in the flow |
| 2 | "You must specify a value for DTMF Response Values" | Empty `responseValues` | Use `*` for free-digit entry |
| 3 | "Property 'timeoutPathUsage' not valid in version 65.0"; `disableRecAndTranscription` invalid | API too low (Play Prompt ≥65, rec/transcription ≥66, external transfer ≥67) | package.xml version 68.0 |
| 4 | Calls queue but no agent rings | Queue passed in a variable; or agent setup missing | Fixed queue in Route Work; Voice PSL + Native Voice agent permission set + queue + presence with `sfdc_phone` + Omni re-login |
| 5 | Agent still gets nothing after a permission change | Stale Omni session | Offline → reload → Available |
| 6 | `UnsupportedMediaNameError` / "No such column 'IsDefault' on entity 'VoiceEngagementMediaUsage'" | Platform bug in Media prompts | Don't use flow media for hold audio; raise a case |
| 7 | Queue music stops after in-queue flow | `inQueueFlowAction` | Don't use it |
| 8 | Intent/other flows don't see the AI summary | After-save flows evaluate once per record per transaction | Summary flow on AsyncAfterCommit path (`doesRequireRecordChangedToMeetCriteria=true`) |
| 9 | Made-up AI summary on a silent call | Empty transcript sent to the prompt | "Has transcript?" gate; prompt returns a fixed "summary unavailable" |
| 10 | Talk time 0:00:00 | `CallRecordingId` empty on Native Voice; recording rows saved later and can't fire triggers | Scheduled path after `CallEndDateTime` sums `VoiceCallRecording.DurationInSeconds` |
| 11 | No recording on IVR-only calls | Recording starts when an agent joins | Expected |
| 12 | No transcript on agent click-to-dial outbound calls | No flow runs; platform doesn't transcribe them | Salesforce case; inbound and auto-dial callbacks are transcribed |
| 13 | Teammate's draft flow lost | Deploy over a Draft | Check active = latest first |
| 14 | Flow still active after deploying Obsolete | Obsolete deploy adds an inactive version | Deactivate via FlowDefinition |
| 15 | `SourceConflictError` | Someone edited in the org | Check audit trail; retrieve or deploy with `--ignore-conflicts` deliberately |
| 16 | "not a valid value for the enum FlowComparisonOperator", "Invalid name character" | Script XML errors: PowerShell array flattening, element types not grouped | `@(,@(...))`; group elements by type; formulas before `interviewLabel` |
| 17 | Test number rejected | 555-01xx exchanges invalid for calls | Use 202-555-0100 style synthetic numbers |
| 18 | All inbound calls end in 1–3 s with System Issue | Platform/telephony incident or telephony setting change, not flow logic | Check setup audit trail and Salesforce status; confirm no flow change in the window before editing flows |
| 19 | "Uncommitted work pending" | Invocable doing callouts without `callout=true` | Add `callout=true` |
| 20 | VoiceCall account wrong | Account set from the caller's Contact, not the dialed number | Fix test contacts' account |
| 21 | Every callback falls back to the live queue | Callback queue doesn't list Contact Request as a supported object, so Route Work faults | Setup → Queues → add Contact Request |
| 22 | Agent clicks a callback number and nothing is dialed | Contact Request created with `IsCallback=false` | `IsCallback=true`, `IsPreviewCallback=true` (preview: agent accepts, then clicks) |
| 23 | Callback dial ends at 0 s with `SYSTEM_ISSUE`; a second click rings | Callback dialer path failing for that agent/number (seen when the agent had an earlier participant record with the same number); auto-dial affected too | Check `CallDurationInSeconds`, `DisconnectReason`, `CallerId`, not just that a VoiceCall exists; retest with a number the agent never handled; raise a case |
| 24 | One client's callback or cleanup changed another client's request | Lookup by phone number only | Filter every query by client key (`IVR_Client__c`) and number |
| 25 | A client's post-call/callback flow runs on other clients' calls | Record-triggered flow with no client in its entry criteria | Add `IVR_Client__c = <KEY>` or the client's phone numbers; checker `client-scope` |
| 26 | New client's callers hear the old client's prompts or reach its queue | Copied flows still reference the old client's subflows/queues | Grep copies for the old key; re-select fixed queues; checker `client-isolation` |
| 27 | Transcript query returns 0 rows although the Conversation panel shows lines | SOQL on `ConversationEntry` doesn't return Native Voice entries | Count via REST `/connect/conversation/<ConversationIdentifier>/entries` (`diagnostics.md`) |
| 28 | Formula shows a value when the number field is blank | Formula treats blanks as zero, so `ISBLANK(number)` is always false | Test `<= 0` instead of `ISBLANK` |
| 29 | Test fails: "DML operation INSERT not allowed on VoiceCallRecording"; or the value you set is wiped by a trigger | Platform object not insertable in tests; a shared VoiceCall trigger recalculates on update | Inject durations through a `@TestVisible` static map; assert on a `@TestVisible` result list, not the re-queried record |
| 30 | Anonymous Apex fails to compile at line 1 with an odd character | File saved with a UTF-8 BOM | Save anonymous Apex without BOM |
| 31 | "field can't be filtered in query" on a summary or description field | Long text area fields can't be used in `WHERE` | Query by Id / date and filter in code |
| 32 | Script stops on "update available" from `sf` under Windows PowerShell | 5.1 turns native stderr into an error when `$ErrorActionPreference='Stop'` | Set `SF_SKIP_NEW_VERSION_CHECK=true` and call `sf` with a local `Continue` preference (as `Deploy-IvrFlow.ps1` does) |
