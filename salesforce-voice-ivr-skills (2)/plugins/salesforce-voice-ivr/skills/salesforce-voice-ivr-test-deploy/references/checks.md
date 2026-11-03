# Static checker and simulator

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
