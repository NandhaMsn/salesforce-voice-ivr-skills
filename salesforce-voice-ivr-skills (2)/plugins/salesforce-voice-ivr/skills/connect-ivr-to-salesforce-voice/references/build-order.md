# Build order and manual setup

## Create by hand in every org (not deployable or org-specific)
1. Business Hours record with the exact name the Apex looks up, including holidays.
2. Phone number channels (Setup → Messaging Settings, voice channel) pointing at the entry flow, plus a fallback queue.
3. Omni-Channel presence statuses that include the `sfdc_phone` channel.
4. Queue membership / routing groups for agents.
5. Agent licences: Salesforce Voice permission set licence + the Contact Center agent permission set for Native Voice (not the External Telephony ones).

## Deploy order (package.xml version 68.0 or higher)
1. VoiceCall custom fields (IVR details, summary, talk time).
2. Custom labels / named or external credentials for back-end APIs (never secrets in custom metadata).
3. Apex invocable classes with tests.
4. Permission set for the Platform Integration User (Apex class access).
5. Queues and routing configurations.
6. Autolaunched service subflows that wrap Apex.
7. Feature routing flows (e.g. amount due, payments, outage report).
8. Queue-transfer flow and any direct-to-agent flow.
9. Language main menus.
10. Entry flow.

## After deploy
- Re-select the fixed queue in every Route Work (queue IDs differ per org).
- Replace org-specific constants (record IDs, transfer numbers).
- Check voices per prompt.
- Fresh Omni-Channel login for every agent whose permissions changed.
