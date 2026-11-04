# Build order and manual setup

## Create by hand in every org (not deployable or org-specific), per client
1. Business Hours record with the exact name the Apex looks up (`<KEY> Business Hours`), including holidays.
2. Phone number channels (Setup → Messaging Settings, voice channel) pointing at the entry flow, plus a fallback queue.
3. Omni-Channel presence statuses that include the `sfdc_phone` channel.
4. Queue membership / routing groups for agents.
5. Agent licences: Salesforce Voice permission set licence + the Contact Center agent permission set for Native Voice (not the External Telephony ones).
6. Callback queues (per language) with **Contact Request** as a supported object; agents' presence status includes the callback channel.
7. Outbound caller ID for the client's callbacks.

## Deploy order (package.xml version 68.0 or higher)
1. VoiceCall / ContactRequest custom fields (IVR details, `IVR_Client__c`, summary, talk time). Shared: deploy once, reused by later clients.
2. Custom labels / named or external credentials for back-end APIs (never secrets in custom metadata); `IVR_Client_Config__mdt` type (shared) and the client's record.
3. Apex invocable classes with tests (shared; skip if unchanged for a new client).
4. Permission set for the Platform Integration User (Apex class access).
5. Queues and routing configurations.
6. Autolaunched service subflows that wrap Apex.
7. Feature routing flows (e.g. amount due, recent payments, outage report).
8. Callback-offer flow, then agent-handoff flow and any direct-line flow.
8a. Client-scoped record-triggered flows (callback close / withdraw, talk time).
9. Language main menus.
10. Entry flow.

## After deploy
- Re-select the fixed queue in every Route Work (queue IDs differ per org).
- Replace org-specific constants (record IDs, transfer numbers).
- Check voices per prompt.
- Fresh Omni-Channel login for every agent whose permissions changed.
