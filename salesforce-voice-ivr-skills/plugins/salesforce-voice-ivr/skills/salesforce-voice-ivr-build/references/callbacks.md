# Callback feature (per client)

Each client has its own callback-offer flow, callback queue per language and config record. The Apex service is shared and always takes `clientKey`. Names are suggestions; see `multi-client.md` for naming and isolation.

## Call path
Agent handoff (`IVR_<KEY>_Agent_Handoff`) → hours check → callback offer (only if the client's config enables it for that language) → `callbackRequested` → `true`: end call; `false`: transcription on → Route Work to the live queue.

### Callback-offer subflow (`IVR_<KEY>_<LANG>_Callback_Offer`)
1. `checkAvailabilityForRouting` on the client's **live** queue (fixed queue). Agent free = `onlineAgentsCount >= 1` AND `queueSize < onlineAgentsCount`. Free → `callbackRequested=false`.
2. Busy → spoken hold message with a listen window → check again. Free → `false`.
3. Still busy → "Press 1 to keep waiting, 2 for a callback." Silence / wrong key per the retry pattern → keep waiting.
4. Callback number: `responseValues=*`, exact length for the country (10 in North America), read back digit by digit, 1 confirm / 2 re-enter. Too many invalid entries → keep waiting.
5. Apex `reserve` (clientKey, number, language, VoiceCall Id) → `RESERVED` (request Id) | `EXISTS` (offer keep / replace) | `INVALID_NUMBER` | `ERROR` (→ keep waiting).
6. Route Work: record = Contact Request Id, callback service channel, QueueBased, **fixed** callback queue for the client and language. Fault → `cancel` the request → keep waiting.
7. After routing succeeds: Apex `removeOlder` (clientKey, number, keep = new Id): one open request per number **per client**. Run it after routing so a failed new request never removes the old one.
8. Confirmation → `callbackRequested=true` → end call.

Every Apex action and Route Work has a fault path that ends in "keep waiting": a broken callback must never drop the caller.

### Contact Request fields
| Field | Value |
|---|---|
| `PreferredPhone` | caller-entered number, normalized to E.164 |
| `WhatId` | VoiceCall Id |
| `IsCallback`, `IsPreviewCallback` | `true`, `true`: preview (agent accepts, then clicks to dial) |
| `AvailableCallbackAttempts`, `DelayBetweenCallbackAttempts` | from client config |
| `IVR_Client__c` | client key (filterable) |
| `RequestDescription` | short neutral text (`Callback (EN)`); no caller data. Long text, so it can't be filtered in SOQL |
| `Status` | `New` → `Attempted` → `Contacted` / `Abandoned` |

## After the call: per-client record-triggered flows
| Flow | Trigger | Entry criteria (must include the client) | Action |
|---|---|---|---|
| `IVR_<KEY>_Callback_Close` | VoiceCall after-save, create | `CallType = Outbound`, `ToPhoneNumber` set, `FromPhoneNumber` = client's outbound caller ID | `closeByNumber` → client's open requests for the dialed number → `Contacted` |
| `IVR_<KEY>_Callback_Withdraw` | VoiceCall after-save, update, only when changed | `CallType = Inbound`, `CallAcceptDateTime` set, `IVR_Client__c = <KEY>` | `withdrawByNumber` → client's open requests for the caller's number → `Abandoned`, removed from Omni |

Both: fault path → assignment that swallows the error, so the call record always saves. They match by number because Contact screen pop can replace the VoiceCall's related record.

## Apex service contract (shared, client-neutral)
`CallbackRequestService`, `@InvocableMethod(label='Voice: Callback request')`, operations `reserve | replace | cancel | removeOlder | closeByNumber | withdrawByNumber`; inputs `clientKey` (required), `phoneDigits`, `languageCode`, `voiceCallId`, `requestId`; outputs `result` (`RESERVED | EXISTS | INVALID_NUMBER | CANCELLED | REMOVED | CLOSED | ERROR`), `requestId`, `errorCode`.
- Validate input: digits only, expected length, reject anything else as `INVALID_NUMBER`; normalize before storing.
- Every query uses bind variables and filters by client: `WHERE PreferredPhone = :phone AND IVR_Client__c = :clientKey AND Status IN ('New','Attempted')`.
- Settings come from `IVR_Client_Config__mdt` by `clientKey`; unknown key → `ERROR` (never fall back to another client).
- Prefer `with sharing`; use `without sharing` only when the integration user can't otherwise see the requests, document why, and keep the client filter in every query.
- Never log phone numbers or names; log the result code and record Id only.
- Tests: two synthetic clients with the **same** synthetic number; prove each operation for client A never touches client B.

## Setup per client (by hand)
1. Callback queue per language with **Contact Request** in Supported Objects (without it every callback fails to route).
2. Callback service channel in the queue's routing configuration; agents' presence status includes it.
3. Outbound caller ID for the client's callbacks (used in the close flow's entry criteria).
4. `IVR_Client_Config__mdt.<KEY>`: callbacks enabled per language, attempts, delay.

## Testing (live, inside hours, synthetic numbers only)
1. All agents busy → book a callback → request in the client's callback queue, call ends.
2. Agent accepts and clicks → test phone rings; request becomes `Contacted`. Check `CallDurationInSeconds` and `DisconnectReason`, not just that a VoiceCall exists.
3. Book twice with the same number → only the newest request stays open.
4. Book, then call in and reach an agent → request `Abandoned`.
5. Cross-client: book the same number for clients A and B → each client's agents see only their own request; closing A leaves B open.
