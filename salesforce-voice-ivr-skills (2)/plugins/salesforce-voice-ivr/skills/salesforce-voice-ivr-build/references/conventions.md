# Prompt and keypad conventions

## Prompt element (`playPromptAsyncAction`)
| Setting | Menu / yes-no | Free-digit entry (account number, ZIP, phone) | Message only |
|---|---|---|---|
| `promptType` | Message | Message | Message |
| `languageValue` | e.g. en-US / es-MX | same | same |
| `voiceProfileValue` | chosen voice (set on every prompt) | same | same |
| `userResponseSettings` | true | true | false |
| `responseValues` | `0,1,2,3,4,5,6,7,8,9,*,#` | `*` (empty fails: "You must specify a value for DTMF Response Values") | – |
| `inputValueLength` | 1 | exact digit count (e.g. 10 account, 5 ZIP, 10 phone) | – |
| `responseTime` | 8 | 10–15 | – |
| `interDigitResponseTimeout` | 5 | 5 | – |
| `requireResponseRetry` | false | false | – |

`requireResponseRetry=true` made inputs count only on the third entry and repeated success prompts three times.

## Retry pattern
- Menus: 1 retry, then goodbye (or agent, per business rule).
- Feature flows: 2 timeouts, then agent.
- Validation failures (e.g. 3 failed account lookups): agent.
- Decision order after a prompt: valid keys → `f_KeyEntered = NOT(ISBLANK(dtmfInput))` → wrong-key message → default no-input message.

## Read-backs
Build digit-by-digit strings with formulas (`MID()` + spaces or `<break time="200ms"/>`). No say-as.

## Speed
No speaking-rate control. Add `<break>` pauses or pick a slower voice.

## Data written to VoiceCall
- Language, menu selection as `code|label` (e.g. `1|1|Amount Due`, `9|Live Agent`), feature `status` and `error` fields.
- Each Update Records has a fault connector that continues the call.
