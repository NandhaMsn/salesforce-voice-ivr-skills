# Static checker and simulator

`scripts/Test-IvrFlow.ps1` implements the checks below. Check ids in its output:

| Id | Severity | Rule |
|---|---|---|
| `connector-target` | ERROR | 1 |
| `reachable` | WARN | 2 |
| `prompt-text` | ERROR | 3 |
| `prompt-language` | ERROR | 4 (language from the prompt name `_EN`/`_ES`/English/Spanish, then the flow name, then `-Language`; mixed flows without hints are skipped) |
| `fault-path` | ERROR | 5 (also recordCreates / recordLookups / recordDeletes) |
| `decision-key` | ERROR | 6 (follows the key through an Assign from `<Prompt>.dtmfInput` into a variable) |
| `dead-end` | ERROR | 7: a prompt that collects a key with no next element. Other elements without a connector are normal subflow returns |
| `subflow` / `subflow-org` | WARN / ERROR | 8 |
| `prompt-retry` | ERROR | traps.md #1 |
| `prompt-keys` | ERROR / INFO | traps.md #2; INFO when a prompt accepts only some keys |
| `api-version` | ERROR | traps.md #3 |
| `route-queue` | WARN | traps.md #4 |
| `prompt-ssml` | ERROR | only `<break>` and `<phoneme>` |
| `prompt-voice` | WARN | `voiceProfileValue` missing |
| `client-isolation` | ERROR | with `-ClientPrefix`: subflow outside the client's prefix and not in `-SharedFlows` (traps.md #26) |
| `client-scope` | WARN | with `-ClientPrefix`: record-triggered flow without `IVR_Client__c` or a `*PhoneNumber` equals/starts-with filter (traps.md #25) |
| `hardcoded-secret` | ERROR | a literal string in a parameter named like a key/token/tenant/credential, or a 24+ character letters-and-digits token; element named, value never shown |
| `parse` | ERROR | not valid XML, or contains a DTD (refused for safety) |

Self-tests: `fixtures/IVR_Test_Broken_EN.flow-meta.xml` must report 16 errors / 6 warnings (its key is fake); `fixtures/multi-client` with `-ClientPrefix IVR_ACME_` must report 1 error (`client-isolation`) and 2 warnings (`client-scope`, `subflow`).

## Static checks per flow (XML)
1. Every `targetReference` (connectors, fault connectors, defaults, rules) points to an existing element.
2. Every element is reachable from `start`.
3. Every `playPromptAsyncAction` has non-empty prompt text.
4. Prompt `languageValue` matches the flow's language (English flows en-US, Spanish flows es-MX).
5. Fault connectors exist on `apex` actions, `routeWork`, `externalTransferAsyncAction` and `recordUpdates`.
6. Decision rules that test a prompt's `dtmfInput` only compare against values in that prompt's `responseValues` (or any value when `*`).
7. No dead ends: every non-terminal path reaches an end, a subflow return or a routing action.
8. Every `subflows/flowName` exists locally and is active in the org.

## Simulator
- Parse the flow XML into elements; walk from `start`.
- Prompts consume the next scripted key (`X` = timeout/no input) and set `<Element>.dtmfInput`.
- Evaluate formulas used in decisions (`NOT`, `ISBLANK`, `LEN`, `MID`, `VALUE`, `AND`, `OR`, comparisons).
- Subflows: recurse, pass inputs, read outputs (`nextStep`).
- Mock Apex results per scenario (success, each error code, fault).
- Mock Route Work and external transfer (success / fault).
- Record a trace of prompts played and the final outcome; assert outcome and key prompts.
- Not modelled: platform retries, in-queue actions, real audio timing.

## Control runs
Run every scenario against the previous active versions. Expect failures only in scenarios touching the change. A control run that passes everything means the scenarios don't exercise the change.
