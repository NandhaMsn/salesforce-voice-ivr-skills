# Multi-client contact center (one org, many clients)

One Salesforce org hosts several clients' IVRs. Each client gets its own flows, queues, business hours and callback setup. Nothing a caller hears, and no record a client's agents work, may come from another client's configuration.

## Client key
Pick a short, stable key per client before building anything, e.g. `ACME` (letters/digits, upper case). Optional line or region suffix: `ACME_WEST`.

| Used for | Pattern |
|---|---|
| Flow API names | `IVR_<KEY>_<Purpose>` e.g. `IVR_ACME_Entry`, `IVR_ACME_EN_Menu`, `IVR_ACME_Agent_Handoff`, `IVR_ACME_EN_Callback_Offer` (full list: `flow-catalog.md`) |
| Queues | `<KEY>_<Lang>_Live`, `<KEY>_<Lang>_Callback` (DeveloperName); label `<Client> <Language> Live Calls` |
| Business Hours | `<KEY> Business Hours` |
| Custom metadata record | `IVR_Client_Config__mdt.<KEY>` |
| VoiceCall / ContactRequest field value | `IVR_Client__c = '<KEY>'` |
| Permission sets | `<KEY>_Voice_Agent` (queue access, Omni presence) |
| Apex | Shared classes, no client names in code; client passed in as `clientKey` |

Never put a client's display name in shared Apex, shared flows, skill files or logs; use the key. Keys like `ACME` / `GLOBEX` in these files are placeholders.

## What is per client vs shared

| Per client (separate copy) | Shared (one copy, client passed in) |
|---|---|
| Entry flow, menus, feature flows, agent-handoff flow, callback-offer flow | Apex invocable services (callback requests, hours check, back-end lookups) |
| Prompts, voices, languages offered | VoiceCall / ContactRequest custom fields |
| Live and callback queues per language, routing configurations | Service channels (`sfdc_phone`, callback channel) |
| Business Hours record and holidays | Presence statuses (one per channel mix) |
| Record-triggered flows, **or** one shared flow scoped by `IVR_Client__c` (see below) | Post-call AI summary flow (if all clients use the same prompt template) |
| Named/External Credentials when back ends differ | |

**Why flows are per client:** Route Work needs a **fixed** queue (a queue in a variable may not ring agents, traps.md #4), prompts differ, and one client's change must not redeploy another client's live flow.

## Isolation rules
1. **Tag every call.** The entry flow's first element writes `IVR_Client__c = '<KEY>'` (plus language) to the VoiceCall, with a fault path that continues the call. Everything downstream filters on it.
2. **Never cross-call.** A client's flow calls only its own subflows (`IVR_<KEY>_*`) or explicitly shared, client-neutral flows. `Test-IvrFlow.ps1 -ClientPrefix IVR_<KEY>_` enforces this.
3. **Scope every record-triggered flow.** Entry criteria must include the client: `IVR_Client__c = '<KEY>'`, or the client's dialed numbers (inbound `ToPhoneNumber`, outbound `FromPhoneNumber`) when the field may not be set yet (outbound/click-to-dial calls have no IVR). A VoiceCall trigger with no client filter fires on **every** client's calls.
4. **Scope every query.** Apex that finds records by phone number also filters by client: the same person can be a caller for two clients.
5. **Separate queues, separate agents.** Agents get the client's permission set and queue membership only. An agent who serves two clients is in both queues knowingly.
6. **Per-client config in custom metadata, not code.** `IVR_Client_Config__mdt` fields: client key, business hours name, callback enabled (per language), callback queue DeveloperNames, callback attempts and delay, outbound caller ID. No secrets here: back-end credentials live in Named/External Credentials (`security.md`). Apex reads it by `clientKey`. Queue IDs are **not** stored here for Route Work (flows keep fixed queues); Apex may resolve queues by DeveloperName.
7. **Deploy per client.** A package contains one client's flows (+ shared components only when changed and approved). Shared components affect every client: test all clients after changing them.

## Adding a new client (checklist)
1. Agree the key, languages, phone numbers, hours, menu tree, which features (self-service, callback, transfer numbers).
2. Copy the closest existing client's flows to `IVR_<NEWKEY>_*`, then rename every reference inside: subflow `flowName`, `IVR_Client__c` value, queue labels, business-hours name, interview labels. Grep the copies for the old key; zero hits allowed.
3. Create queues (live + callback per language; callback queues need **Contact Request** as a supported object), routing configs, Business Hours, permission set, `IVR_Client_Config__mdt` record.
4. Re-select the fixed queue in every Route Work of the new flows.
5. Scope the new client's record-triggered flows (rule 3).
6. Run `Test-IvrFlow.ps1 -Path <flows> -ClientPrefix IVR_<NEWKEY>_`.
7. Point the client's phone number channel at `IVR_<NEWKEY>_Entry`.
8. Live-test the new client **and** one call per existing client (to prove nothing leaked), with synthetic test numbers only.
