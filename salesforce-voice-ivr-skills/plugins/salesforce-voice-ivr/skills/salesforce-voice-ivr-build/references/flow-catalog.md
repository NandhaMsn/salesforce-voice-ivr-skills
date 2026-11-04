# Flow catalog: every flow in a client's IVR

Blueprints for each flow a client gets. Names use the client key (`IVR_<KEY>_*`, see `multi-client.md`). Feature examples come from a made-up city utility line (amount due, recent payments, outage report, start service); substitute the client's own features, the patterns stay the same. Every name below is a suggestion; when an org already has its own names, follow the org.

For every blueprint built out in full (keys, prompts, steps, tests), see the worked example in `reference-ivr.md`.

## Find the blueprint for a common feature
Most self-service phone lines offer some mix of these. Each one is a pattern below; only the prompts, the typed factors and the Apex `operation` change.

| Caller wants to… | Blueprint | Section |
|---|---|---|
| Hear a balance, amount owed or status | Verified self-service, variant **Look up and read back** | 3 |
| Hear recent transactions, payments or orders | Verified self-service, variant **Look up a list** | 3 |
| Report something lost, stolen or broken; block it and order a replacement | Verified self-service, variant **Request with a reason** (protective step first, confirm before acting) | 3 |
| Activate or enrol something new, with consent or terms to accept | Verified self-service, variant **Enrolment with acknowledgements** (+ service subflow) | 3, 4 |
| Be transferred to a partner or another company's line | Menu option **External transfer** (number from config; failure → agent) | 2 |
| Hear information only (opening hours, website, PIN or password help) | Menu option **Information only** | 2 |
| Talk to a person | **Agent handoff** (hours check → hold message → transcription on → fixed queue per language) | 5 |
| Get called back instead of waiting | **Callback offer** inside agent handoff | 5, 6 |
| Reach agents directly on a separate number | **Direct line** | 7 |

## The set for one client

| Flow | Type | Called by | Returns / ends |
|---|---|---|---|
| `IVR_<KEY>_Entry` | Routing | phone number channel | ends the call |
| `IVR_<KEY>_<LANG>_Menu` (one per language) | Routing subflow | entry | `menuSelection` |
| `IVR_<KEY>_<LANG>_<Feature>` (one per feature per language) | Routing subflow | menu | `nextStep`, `menuSelection` |
| `IVR_<KEY>_<Feature>_Service` (optional) | Autolaunched subflow | feature flows | `status`, `errorCode` |
| `IVR_<KEY>_Agent_Handoff` | Routing subflow | menus (every agent path) | Route Work or closed message |
| `IVR_<KEY>_<LANG>_Callback_Offer` | Routing subflow | agent handoff | `callbackRequested` |
| `IVR_<KEY>_Direct_Line` (optional) | Routing | its own phone number | Route Work |
| `IVR_<KEY>_Callback_Close`, `IVR_<KEY>_Callback_Withdraw` | Record-triggered (VoiceCall) | platform | update Contact Requests |
| `IVR_<KEY>_Talk_Time` | Record-triggered, scheduled path | platform | fills talk time |
| Post-call summary | Record-triggered (shared or per client) | platform | saves summary |

One menu and one copy of each feature flow per language. Copies differ only in prompt text, `languageValue` and voice; keep their structure identical so every fix goes into every copy.

## Shared contracts
- **Inputs to every routing subflow:** `recordId` (VoiceCall Id), `languageCode` (e.g. `en`, `es`).
- **Feature output:** `nextStep` = `END` | `MAIN_MENU` | `AGENT` (default `END`) and `menuSelection` as `code|label` (e.g. `1|1|Amount Due`).
- **Returning from a subflow:** an assignment that sets `nextStep` and has no connector. That is the return, not a dead end.
- **VoiceCall fields** (suggested): `IVR_Language__c`, `IVR_Menu_Selection__c`, `IVR_<Feature>_Status__c`, `IVR_<Feature>_Error__c`. Every Update Records has a fault path that continues the call. Never store spoken account data or read-back text containing personal data.
- **Shared Apex** takes `clientKey` and an `operation`; back-end identifiers for the client (account codes, endpoints) come from the client config or a Named Credential, never typed into flows.

---

## 1. Entry flow
1. `disableRecAndTranscription`: recording on, transcription off (only the agent leg is transcribed later). Fault → continue.
2. Tag the call: Update VoiceCall `IVR_Client__c = <KEY>` (multi-client orgs). Fault → continue.
3. Greeting (message only).
4. Language choice; each language's sentence is its own prompt element with that language's `languageValue` (name it with the language suffix, e.g. `Ask_Language_ES`).
5. Key 1 / 2 → save language → that language's menu. Wrong key / no input → one retry with the matching message, then the default language (or goodbye, per business rule).
6. When the menu returns: end call.

## 2. Language menu
**Prompt:** one key per feature or feature group, `9` agent, `#` repeat. Accept all keys.

**Decision layout** (same for every menu and submenu):
- `Route_<Menu>`: one rule per key → `Pick_<Option>` assignment (sets `menuSelection`) → target.
- default → retry check: tries left → add try → wrong key? (`f_<menu>Pressed`) "That isn't an option" : "We didn't hear a choice" → menu again.
- no tries left → matching message → end call.
- `#` → repeat check: under the limit → menu again; over → agent handoff.

**Submenus:** a group key plays a second prompt with its own counters; codes nest (`1|2|Recent Payments`).

| Option type | Example | Build |
|---|---|---|
| Feature subflow | amount due, recent payments | subflow → `Next_Step_Router` |
| Information only | "You can also do this online at…" | message; `0` menu, otherwise end |
| External transfer | the gas emergency line | `externalTransferAsyncAction` (recordId, fromNumber, toNumber from config); fault → agent handoff |
| Agent | `9` | `9|Agent` → agent handoff |

**`Next_Step_Router`** after every feature: `MAIN_MENU` → reset counters → menu; `AGENT` → agent handoff (pass `languageCode`, `menuSelection`); otherwise end.

## 3. Feature subflow (verified self-service)
The skeleton every self-service feature follows:

```
Ask factor A → confirm A → Ask factor B → confirm B
  → Apex operation (clientKey, operation, A, B)
       ok    → read back result → "0 for the menu" (else end)
       fail  → help menu: 0 menu, 1 / anything else → AGENT
```

### Digit-capture block (reuse for each factor)
| Element | Settings / logic |
|---|---|
| `Ask_<Factor>` | `responseValues=*`, `inputValueLength` = exact length, `responseTime` 10–15 |
| `Keep_<Factor>` | `<factor>Digits = Ask_<Factor>.dtmfInput` |
| entered? | no → silence counter; limit (e.g. 2) → `AGENT` |
| valid? | no → invalid counter + message → ask again; limit (e.g. 3) → help menu |
| `Confirm_<Factor>` | "You entered {!f_<factor>ReadBack}. Press 1 if that's right, 2 to re-enter." all keys, length 1 |
| confirm route | 1 → next; 2 → ask again; other / none → message → confirm again (limited) |

**Formula patterns** (adapt names and lengths):
```
f_<factor>Pressed     NOT(ISBLANK({!<factor>Digits}))
f_accountOk           LEN({!accountDigits}) = 10 && ISNUMBER({!accountDigits})
f_zipOk               LEN({!zipDigits}) = 5 && ISNUMBER({!zipDigits})
f_startDateOk         LEN({!dateDigits}) = 8 &&                           (MMDDYYYY, e.g. a move-in date)
                      VALUE(LEFT({!dateDigits}, 2)) BETWEEN 1..12 &&      (write as AND(>=, <=) in Flow)
                      VALUE(MID({!dateDigits}, 3, 2)) BETWEEN 1..31 &&
                      VALUE(RIGHT({!dateDigits}, 4)) BETWEEN YEAR(TODAY())..YEAR(TODAY())+1
f_dateReadBack        LEFT({!dateDigits}, 2) & " " & MID({!dateDigits}, 3, 2) & " " & RIGHT({!dateDigits}, 4)
f_digitsReadBack      one MID({!x}, n, 1) per digit joined with " " (or <break time="200ms"/>)
```
Read back only what the caller just typed; never read back data fetched from the back end that the caller didn't provide (e.g. a service address or full account number) unless the business requires it and the caller is verified.

### Apex step
Shared invocable: inputs `clientKey`, `operation`, the factors; outputs `speech` (text to play, no unnecessary personal data), `errorCode` (`OK` on success). Fault connector → assignment sets an error → help menu. Save status / error code on the VoiceCall (fault → continue).

### Help menu
"Sorry, we couldn't complete that. Press 0 for the main menu or 1 for an agent." `0` → `MAIN_MENU`; anything else or silence → `AGENT`.

### Variants
| Pattern | Example | Extra steps |
|---|---|---|
| Look up and read back | amount due and due date | read back one value |
| Look up a list | recent payments | read back the last N items; cap N (e.g. 3) |
| Request with a reason | report an outage | reason menu; for safety reasons (e.g. gas smell, downed line) do the protective step first (transfer to the emergency line), then the request; confirm before acting |
| Enrolment with acknowledgements | start service at a new address | one prompt per required acknowledgement (terms, deposit; press 1 to accept; decline → `AGENT` or end per business rule), then submit through a service subflow; any non-success → `AGENT` |

## 4. Service subflow (autolaunched)
Wraps one Apex call so several routing flows (e.g. all language copies) share it.
- Inputs: factors + `clientKey`. Outputs: `status`, `errorCode`, `needsAgent`.
- Apex fault → assignment sets `status=ERROR` and ends.
- No prompts and no VoiceCall updates; the calling flow speaks and saves.

## 5. Agent handoff
1. Save IVR details on the VoiceCall. Fault → continue.
2. Hours check for the client (Apex, `clientKey`). Fault → treat as open.
3. Closed → closed message in the caller's language → end.
4. Open → callback offer when enabled for the client and language (`callbacks.md`); `callbackRequested=true` → end.
5. Hold message → transcription on (fault → continue) → Route Work QueueBased on `sfdc_phone` to the **fixed** live queue for that language.
6. Route Work fault → error message → end.
Default queue music only: no in-queue flow action, no flow media for hold audio.

## 6. Callback offer
See `callbacks.md`. Input `recordId`; output `callbackRequested`. Every fault → `false` (caller goes to the live queue).

## 7. Direct line (no menu)
A separate number for callers who should reach agents directly (e.g. field crews): hours check (fail open) → closed message, or recording notice → transcription on → Route Work to the client's direct-line queue.

## 8. Record-triggered flows
| Flow | Trigger | Entry criteria (always scoped to the client) | Does |
|---|---|---|---|
| Callback close | VoiceCall create | Outbound, `ToPhoneNumber` set, client's caller ID | Apex: client's open requests for that number → `Contacted` |
| Callback withdraw | VoiceCall update, only when changed | Inbound, `CallAcceptDateTime` set, client | Apex: client's open requests for that number → `Abandoned` |
| Talk time | VoiceCall create/update, only when changed; **scheduled path** a few minutes after `CallEndDateTime` | Call ended + client | Apex sums `VoiceCallRecording.DurationInSeconds` |
| Post-call summary | VoiceCall update, async-after-commit | `CallAcceptDateTime` set, client | transcript → "has transcript?" gate → prompt template → save |
All: fault path → assignment that keeps the error, so the call record always saves.

## Patterns to avoid
| Pattern | Problem | Instead |
|---|---|---|
| One autolaunched flow that returns prompt text and the next step for every step of a conversation | Hard to test; every call re-sends all inputs | One routing subflow per feature |
| Callback offer through `inQueueFlowAction` | Queue music stopped afterwards | Offer before Route Work |
| Hold music from flow media prompts | Platform media errors | Spoken hold message + default queue music |
| `requireResponseRetry=true` | Input counted only on the third try | `false` + counters in the flow |

## Adding a feature flow
1. Copy a feature flow of the same client and pattern; rename file, label and interview label.
2. Change factors, the Apex `operation`, the read-back and the `menuSelection` code.
3. Make each language copy with the same structure.
4. Add the key and `Pick_<Option>` in every language menu; connect to `Next_Step_Router`.
5. Run `Test-IvrFlow.ps1 -ClientPrefix IVR_<KEY>_` and fix every ERROR.
