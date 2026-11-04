# Worked example: a complete IVR, flow by flow

A full keypad IVR for a made-up **City Water & Power** customer line (client key `CITY`), built from the blueprints in `flow-catalog.md`. Every flow a production line typically needs is here, each with its keys, steps, outputs, saved fields, fault paths and test scenarios. Copy the shape for a real client, then change the prompts, factors, Apex operations and queues.

All names, numbers and prompts are invented. Synthetic test data: phone `2025550100`, account `0000000001`, ZIP `00000`.

## Flow list

| # | Flow | Type | Blueprint | Business scenario |
|---|---|---|---|---|
| 1 | `IVR_CITY_Entry` | Routing | Entry | Welcome, language choice |
| 2 | `IVR_CITY_EN_Menu`, `IVR_CITY_ES_Menu` | Routing subflow | Menu + submenu | Main menu and account submenu |
| 3 | `IVR_CITY_EN_Start_Service`, `_ES_` | Routing subflow | Enrolment with acknowledgements | Start service at a new address |
| 4 | `IVR_CITY_Start_Service_Service` | Autolaunched | Service subflow | Wraps the start-service Apex call for both languages |
| 5 | `IVR_CITY_EN_Amount_Due`, `_ES_` | Routing subflow | Look up and read back | Amount due and due date |
| 6 | `IVR_CITY_EN_Recent_Payments`, `_ES_` | Routing subflow | Look up a list | Last three payments |
| 7 | `IVR_CITY_EN_Meter_Problem`, `_ES_` | Routing subflow | Request with a reason | Damaged or stolen meter: lock, confirm address, order replacement |
| 8 | `IVR_CITY_EN_Programs`, `_ES_` | Routing subflow | Look up and read back | Assistance and savings programs the account is enrolled in |
| 9 | `IVR_CITY_Agent_Handoff` | Routing subflow | Agent handoff | Every live-agent path; hours, hold, queue per language |
| 10 | `IVR_CITY_EN_Callback_Offer` | Routing subflow | Callback offer | Callback when all agents are busy |
| 11 | `IVR_CITY_Crew_Line` | Routing | Direct line | Separate number for field crews, straight to agents |
| 12 | `IVR_CITY_Callback_Close`, `IVR_CITY_Callback_Withdraw` | Record-triggered | Callback cleanup | Close a request after the agent calls back; withdraw it if the caller gets through first |
| 13 | `IVR_CITY_Talk_Time` | Record-triggered, scheduled path | Talk time | Fill talk time from recordings |
| 14 | Post-call summary (shared) | Record-triggered, async | AI summary | Summary for agent-handled calls with a transcript |

Menu options without their own flow: **2 → partner transfer** (external transfer), **1-4 → login and PIN help** (information only), **9 → agent**.

## Call chain

```mermaid
flowchart TD
  N([Main number]) --> E[1 Entry<br/>1 English / 2 Spanish]
  E --> M[2 Menu]
  M -->|1| S[Account submenu]
  S -->|1| SS[3 Start service] --> SV[4 Service subflow] --> API[(Back end)]
  S -->|2| AD[5 Amount due] --> API
  S -->|3| RP[6 Recent payments] --> API
  S -->|4| PIN[Login and PIN help, info only]
  S -->|5| MP[7 Meter problem] --> API
  M -->|2| X[Partner transfer<br/>external number] -.fault.-> H
  M -->|3| PR[8 Programs] --> API
  M -->|9 or 4th #| H[9 Agent handoff]
  SS & AD & RP & MP & PR -.nextStep=AGENT.-> H
  H --> HO{Open?}
  HO -->|no| CL[Closed message, end]
  HO -->|yes| CB[10 Callback offer]
  CB -->|callback booked| END([End call])
  CB -->|keep waiting| Q[Hold message, transcription on,<br/>Route Work to EN or ES live queue]
  C([Crew number]) --> CR[11 Crew line] --> Q2[Crew queue]
```

---

## 1. Entry: `IVR_CITY_Entry`
| Step | Element | Detail |
|---|---|---|
| 1 | Set Recording and Transcription Behavior | recording allowed, transcription off; fault → continue |
| 2 | Update VoiceCall | `IVR_Client__c = CITY`; fault → continue |
| 3 | Prompt (message) | "Thanks for calling City Water and Power." |
| 4 | Prompt `Ask_Language_EN` + `Ask_Language_ES` | "For English, press 1." / "Para español, oprima 2." All keys, length 1, 8 s |
| 5 | Decision | 1 → `languageCode=en`; 2 → `es`; wrong key → "That isn't an option" (once); silence → "We didn't hear a choice" (once); then English |
| 6 | Update VoiceCall | `IVR_Language__c`; fault → continue |
| 7 | Subflow | `IVR_CITY_EN_Menu` or `IVR_CITY_ES_Menu` (input `recordId`, `languageCode`) |
| 8 | End call | after the menu returns |

**Tests:** press 1 → English menu · press 2 → Spanish menu · press 7 then 1 → wrong-key message, English · silence twice → English menu.

## 2. Menu: `IVR_CITY_EN_Menu` (Spanish copy identical in structure)
**Main prompt:** "For your account and bills, press 1. For home appliance rebates, press 2. For assistance and savings programs, press 3. To speak with a representative, press 9. To hear this again, press pound."

| Key | Goes to | `menuSelection` |
|---|---|---|
| 1 | Account submenu | `1|Account` |
| 2 | Partner transfer: message → external transfer (numbers from config); fault → agent handoff. Full steps: §2a | `2|Partner Transfer` |
| 3 | `IVR_CITY_EN_Programs` → `Next_Step_Router` | `3|Programs` |
| 9 | Agent handoff | `9|Agent` |
| # | repeat; the 4th `#` → agent handoff | `#|Repeat` |
| other / none | wrong-key or no-input message, 1 retry, then "Goodbye" → end | – |

**Account submenu:** "To start service, press 1. For your amount due, press 2. For recent payments, press 3. For login and PIN help, press 4. To report a meter problem, press 5. For the main menu, press 0."

| Key | Goes to | `menuSelection` |
|---|---|---|
| 1 | `IVR_CITY_EN_Start_Service` | `1|1|Start Service` |
| 2 | `IVR_CITY_EN_Amount_Due` | `1|2|Amount Due` |
| 3 | `IVR_CITY_EN_Recent_Payments` | `1|3|Recent Payments` |
| 4 | Login and PIN help: information only, 1 repeat / 0 menu / 9 agent. Full steps: §2b | `1|4|Login Help` |
| 5 | `IVR_CITY_EN_Meter_Problem` | `1|5|Meter Problem` |
| 0 | main menu | – |

**`Next_Step_Router`** after every feature: `MAIN_MENU` → reset counters → main menu; `AGENT` → agent handoff (pass `languageCode`, `menuSelection`); else end. Save `IVR_Menu_Selection__c` before each target (fault → continue).

**Tests:** 1-2 → amount due · 2 → transfer (and a forced transfer fault → agent) · 3 → programs · 9 → agent · `#` ×4 → agent · 5 → wrong key, retry, 9 → agent · silence ×2 → goodbye.

## 2a. Partner transfer (menu key 2, inside the menu flow)
No separate flow: these elements sit in `IVR_CITY_EN_Menu` (and the Spanish copy) behind key 2.

| Step | Element / prompt | Rules |
|---|---|---|
| Pick | `Pick_Partner`: `menuSelection = 2|Partner Transfer` | – |
| Save | Update VoiceCall `IVR_Menu_Selection__c` | fault → continue |
| Partner hours (optional) | Apex hours check with the partner's Business Hours record | closed → "Our rebate partner is open Monday to Friday, 9 AM to 5 PM." → back to the main menu; fault → treat as open |
| Message | `Msg_Partner`: "Our rebate partner handles appliance rebates. Please hold while we connect you." | message only |
| Transfer | `externalTransferAsyncAction` (Add External Party to Call): `recordId`, `fromNumber` = this line's number, `toNumber` = partner number in E.164, both from client config (never typed into the flow) | API 67+ |
| Success | The caller is now with the partner; the flow ends with no more prompts | – |
| Fault | "Sorry, we couldn't reach our partner. Let me get you a representative." → agent handoff (pass `languageCode`, `menuSelection`) | never drop the caller |

Setup: the line's number must be allowed to place outbound calls; agents never see the transferred leg as an Omni work item. Test it live: transfers can't be simulated end to end.

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | 2 (partner open) | message, partner line rings, IVR ends |
| 2 | 2 with a bad partner number in config | fault message → agent queue |
| 3 | 2 outside partner hours | hours message → main menu |
| 4 | Spanish caller presses 2 | Spanish message, then transfer |

## 2b. Login and PIN help (account submenu key 4, inside the menu flow)
Information only: no identity check, no Apex.

| Step | Element / prompt | Rules |
|---|---|---|
| Pick | `menuSelection = 1|4|Login Help`; save on VoiceCall | fault → continue |
| Message | "To reset your online login or payment PIN, go to our website and choose Forgot password. For your security, we can't reset it over the phone." | message only; never ask for or read a PIN |
| Next | "To hear that again, press 1. For the main menu, press 0. To speak with a representative, press 9." all keys, length 1 | 1 → message again (once, then end); 0 → reset counters → main menu; 9 → agent handoff; other / none → "Thanks for calling." end |

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | 1, 4, 0 | message, main menu |
| 2 | 1, 4, 1, 1 | message twice, then goodbye |
| 3 | 1, 4, 9 | agent queue, `menuSelection` `1|4|Login Help` saved |
| 4 | 1, 4, silence | goodbye |

## 3. Start service: `IVR_CITY_EN_Start_Service` (enrolment with acknowledgements)
| Step | Prompt / action | Rules |
|---|---|---|
| Gate 1 | "Before we start, please listen to our service terms… Press 1 to continue." | 1 → gate 2; other/none → repeat once → `AGENT` |
| Gate 2 | "A refundable deposit may apply. Press 1 to agree, or 2 to speak with a representative." | 1 → continue; 2 → `AGENT`; other/none → repeat once → `AGENT` |
| Factor A | "Enter your move-in date as two-digit month, two-digit day and four-digit year." `*`, length 8, 15 s | `f_startDateOk`; invalid → message, ask again; 3 invalid → `AGENT`; silence ×2 → `AGENT` |
| Confirm A | "You entered {!f_dateReadBack}. Press 1 if that's right, 2 to re-enter." | 2 → ask again |
| Factor B | "Enter the five-digit ZIP code of the new address." `*`, length 5, 10 s | `f_zipOk`; same counters |
| Confirm B | read back digit by digit | 2 → ask again |
| Submit | Subflow `IVR_CITY_Start_Service_Service` (clientKey, date, ZIP) | outputs `status`, `errorCode` |
| Save | Update VoiceCall `IVR_Start_Service_Status__c`, `IVR_Start_Service_Error__c` | fault → continue |
| Success | "Your request is in. Press 0 for the main menu." | 0 → `MAIN_MENU`; else `END` |
| Not success | "Sorry, we couldn't complete that. Press 0 for the main menu, or 1 for a representative." | 0 → `MAIN_MENU`; anything else or silence → `AGENT` |

**Tests:** 1,1,valid date,1,valid ZIP,1 → success → 0 → menu · gate 2 press 2 → agent · 3 invalid dates → agent · confirm 2 → re-entry works · Apex returns error → help menu → silence → agent · Apex fault → help menu.

## 4. Service subflow: `IVR_CITY_Start_Service_Service`
Inputs `clientKey`, factors. Apex `Voice: Start service` → `status` (`OK` | `FAILED` | `ERROR`), `errorCode` (`INVALID_INPUT`, `NOT_FOUND`, `BACKEND_ERROR`, `SYSTEM_ERROR`). Apex fault → `status=ERROR`. No prompts, no record updates; both language flows call it.

## 5. Amount due: `IVR_CITY_EN_Amount_Due` (look up and read back)
Inputs `recordId`, `languageCode`. Outputs `nextStep` (default `END`), `menuSelection` = `1|2|Amount Due`.

| Step | Element / prompt | Rules |
|---|---|---|
| Ask A | `Ask_Account`: "Please enter your 10-digit account number." `*`, length 10, 10 s | Assign `accountDigits = Ask_Account.dtmfInput` |
| Entered? | `f_accountPressed` | No → silence counter +1 → "We didn't get that." → ask again; 2nd silence → `nextStep=AGENT`, return |
| Valid? | `f_accountOk` (10 digits) | No → invalid counter +1 → "That account number isn't valid." → ask again; 3rd invalid → help menu |
| Confirm A | "You entered {!f_accountReadBack}. Press 1 if that's right, or 2 to enter it again." all keys, length 1 | 1 → Ask B; 2 → reset, ask A; other / none → "Please press 1 or 2." → confirm again (once) → help menu |
| Ask B | `Ask_Zip`: "Now enter the five-digit ZIP code of your service address." `*`, length 5, 10 s | Same entered / valid counters with `f_zipPressed`, `f_zipOk` |
| Confirm B | ZIP read back digit by digit | Same as confirm A |
| Look up | Apex `Voice: Look up amount due` (clientKey `CITY`, operation `amountDue`, factorA, factorB) | Fault connector → `errorCode=SYSTEM_ERROR` → save → help menu |
| Save | Update VoiceCall `IVR_Amount_Due_Status__c` (`OK` / `FAILED`), `IVR_Amount_Due_Error__c` (code) | Never the amount or the digits. Fault → continue |
| Result | `errorCode = OK`? | Yes → read back; no → help menu |
| Read back | Play `speech`: "Your amount due is $84.20, due on May 12." (text built by Apex, capped) | Message only |
| Next | "To hear that again, press 1. For the main menu, press 0." | 1 → read back again (once); 0 → `MAIN_MENU`; other / none → "Thanks for calling." `END` |
| Help menu | "Sorry, we couldn't find that account. Press 0 for the main menu, or 1 for a representative." | 0 → `MAIN_MENU`; anything else or silence → `AGENT` |

Apex result codes used: `OK`, `INVALID_INPUT`, `NOT_FOUND`, `BACKEND_ERROR`, `SYSTEM_ERROR`, `UNKNOWN_CLIENT`. Spanish copy: same structure, `languageValue=es-MX`, Spanish text; the Apex returns Spanish `speech` when `languageCode=es`.

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | account, 1, ZIP, 1 → (OK) → 0 | amount read, `MAIN_MENU`, status `OK` saved |
| 2 | account, 2, account, 1, ZIP, 1 | re-entry works, amount read |
| 3 | silence, silence | `AGENT` |
| 4 | 9-digit entry ×3 | help menu |
| 5 | wrong ZIP → `NOT_FOUND` → 1 | help menu → `AGENT`, error `NOT_FOUND` saved |
| 6 | Apex fault (mock) | help menu, `SYSTEM_ERROR` saved, call continues |
| 7 | after read back, press 1 then 0 | amount repeated once, `MAIN_MENU` |
| 8 | Update VoiceCall fails (mock) | call still reads the amount |

## 6. Recent payments: `IVR_CITY_EN_Recent_Payments` (look up a list)
Outputs `nextStep`, `menuSelection` = `1|3|Recent Payments`.

| Step | Element / prompt | Rules |
|---|---|---|
| Ask A + confirm | account number, as in §5 | same counters and confirm |
| Ask B + confirm | "Enter the 10-digit phone number on the account." `*`, length 10 | `f_phoneOk`; same counters; read back in groups of 3-3-4 |
| Look up | Apex operation `recentPayments` | Fault → help menu |
| Save | status / error code on VoiceCall | fault → continue |
| None found | `errorCode = OK` and count = 0 → "We don't see any payments in the last 90 days." | → Next |
| Read list | `speech` lists up to **3** payments, newest first: "On April 2, $60.00. On March 3, $58.75." | Apex caps the count and length |
| Next | "To hear that again, press 1. For the main menu, press 0." | same as §5 |
| Help menu | as §5 | 0 `MAIN_MENU`, else `AGENT` |

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | account, 1, phone, 1 (3 payments) → 0 | three payments newest first, `MAIN_MENU` |
| 2 | same, account has no payments | "no payments" message → Next |
| 3 | phone, 2, phone, 1 | re-entry works |
| 4 | 9-digit phone ×3 | help menu |
| 5 | `NOT_FOUND` → 1 | help menu → `AGENT`, error saved |
| 6 | Apex fault (mock) | help menu, `SYSTEM_ERROR` saved |
| 7 | after the list, press 1 | list repeated once |

## 7. Meter problem: `IVR_CITY_EN_Meter_Problem` (request with a reason)
Inputs `recordId`, `languageCode`. Outputs `nextStep` (default `END`), `menuSelection` = `1|5|Meter Problem`.

| Step | Element / prompt | Rules |
|---|---|---|
| Ask A + confirm | `Ask_Account`, 10 digits, read back, 1 / 2 | same silence (2 → `AGENT`), invalid (3 → help menu) and confirm rules as §5 |
| Ask B + confirm | `Ask_Phone`: "Enter the 10-digit phone number on the account." read back 3-3-4 | same rules |
| Reason | `Ask_Reason`: "If your meter is damaged, press 1. If it's missing or looks tampered with, press 2. For the main menu, press 0." all keys, length 1, 8 s | 1 → `reason=DAMAGED`; 2 → `reason=MISSING`; 0 → `MAIN_MENU`; other / none → matching message, retry once → `AGENT` |
| Find address | Apex operation `serviceAddress` (clientKey, account, phone) | fault or not `OK` → help menu; `NOT_FOUND` → help menu |
| Address check | "We have your service address as {street number and street name}. Press 1 if that's right, or 2 if it isn't." | 1 → next; 2 → "A representative will help you update it." → `AGENT` (never change an address by keypad); other / none → repeat once → `AGENT` |
| Protective step | Only when `reason=MISSING`: Apex operation `lockMeter` | `OK` → "We've locked the meter remotely for your safety." → next; fault or not `OK` → "For your safety, we'll connect you to a representative now." → `AGENT` (stop; no replacement order) |
| Confirm order | "We'll send a technician to replace the meter. Press 1 to confirm, or 2 to cancel." | 1 → order; 2 → "No problem, nothing was ordered." → Next; other / none → repeat once → `AGENT` |
| Order | Apex operation `orderReplacement` (clientKey, account, reason) | `OK` → "Done. A technician will contact you within two business days." → Next; fault or not `OK` → help menu |
| Save | After each Apex step: `IVR_Meter_Problem_Status__c` (`LOCKED`, `ORDERED`, `FAILED`), `IVR_Meter_Problem_Error__c` | never the address or digits; fault → continue |
| Next | "For the main menu, press 0." | 0 → `MAIN_MENU`; else `END` |
| Help menu | "Sorry, we couldn't complete that. Press 0 for the main menu, or 1 for a representative." | 0 → `MAIN_MENU`; anything else or silence → `AGENT` |

Rules: run the protective step **before** asking to confirm the order, so a stolen meter is locked even if the caller hangs up. Read back only the street number and name (no unit, city or ZIP), and only after both factors match.

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | account, 1, phone, 1, reason 1, address 1, confirm 1 | order placed, status `ORDERED`, Next |
| 2 | … reason 2, address 1 (lock `OK`), confirm 1 | lock then order, statuses `LOCKED` then `ORDERED` |
| 3 | … reason 2, lock fails (mock) | safety message → `AGENT`, no order |
| 4 | … address 2 | `AGENT` |
| 5 | … confirm 2 | "nothing was ordered", Next → 0 → menu |
| 6 | … order fails (mock) | help menu, `FAILED` saved |
| 7 | reason menu: 7, then silence | wrong-key message, then `AGENT` |
| 8 | reason menu: 0 | `MAIN_MENU` |
| 9 | `serviceAddress` → `NOT_FOUND` | help menu → 1 → `AGENT` |

## 8. Programs: `IVR_CITY_EN_Programs` (look up and read back)
Outputs `nextStep`, `menuSelection` = `3|Programs`.

| Step | Element / prompt | Rules |
|---|---|---|
| Ask A + confirm | account number, as in §5 | same counters |
| Ask B + confirm | phone number on the account, as in §6 | same counters |
| Look up | Apex operation `programs` | Fault → help menu |
| Save | status / error code | fault → continue |
| Enrolled | `speech`: "You're enrolled in Budget Billing and the Senior Discount." | → Next |
| Not enrolled | "You're not enrolled in any programs. To hear about them from a representative, press 9." | 9 → `AGENT`; else → Next |
| Next | "For the main menu, press 0." | 0 → `MAIN_MENU`; else `END` |
| Help menu | as §5 | 0 `MAIN_MENU`, else `AGENT` |

**Tests:**
| # | Keys | Expect |
|---|---|---|
| 1 | account, 1, phone, 1 (enrolled) → 0 | programs read, `MAIN_MENU` |
| 2 | same, not enrolled → 9 | `AGENT` |
| 3 | same, not enrolled → 0 | `MAIN_MENU` |
| 4 | `NOT_FOUND` → 1 | help menu → `AGENT` |
| 5 | Apex fault (mock) | help menu, `SYSTEM_ERROR` saved |
| 6 | silence ×2 on account | `AGENT` |

## 9. Agent handoff: `IVR_CITY_Agent_Handoff`
1. Update VoiceCall: language, menu selection. Fault → continue.
2. Apex `Voice: Is the line open` with `CITY Business Hours` (Mon–Fri 08:00–20:00, holidays on the record). Fault → treat as open.
3. Closed → "Our office is closed. We're open Monday to Friday, 8 AM to 8 PM." (EN/ES) → end.
4. Open, English and callbacks enabled → subflow `IVR_CITY_EN_Callback_Offer`; `callbackRequested=true` → end.
5. "Please hold for the next representative." → `disableRecAndTranscription` false/false (fault → continue) → Route Work QueueBased `sfdc_phone`: `languageCode=en` → **CITY EN Live** (fixed), `es` → **CITY ES Live** (fixed).
6. Route Work fault → "Sorry, we can't connect you right now. Please call again." → end.

**Tests:** inside hours EN → EN queue · ES → ES queue · outside hours → closed message · hours Apex fault → still queued · agents busy → callback offer.

## 10. Callback offer: `IVR_CITY_EN_Callback_Offer`
Exactly the `callbacks.md` path: availability check on CITY EN Live → busy → hold message with a listen window → check again → "Press 1 to keep waiting, 2 for a callback" → number entry (10 digits, read back, confirm) → Apex `reserve` → Route Work to **CITY EN Callback** (Contact Request, fixed queue) → `removeOlder` → "We'll call you back." → `callbackRequested=true`. Every fault → `false`.

**Tests:** agent free → no offer · busy, press 1 → keep waiting · busy, press 2, number, 1 → request in callback queue · same number twice → one open request · callback queue missing Contact Request → falls back to live queue.

## 11. Crew line: `IVR_CITY_Crew_Line`
Own number. English only. Hours check (fail open) → closed: "The crew desk is closed. Use the crew portal for non-urgent requests." → end. Open: "This call may be recorded." → transcription on → Route Work to **CITY Crew** queue. No menu.

## 12. Callback cleanup (record-triggered on VoiceCall)
| Flow | Trigger | Entry criteria | Action |
|---|---|---|---|
| `IVR_CITY_Callback_Close` | create | Outbound, `ToPhoneNumber` set, `FromPhoneNumber` = CITY caller ID | Apex `closeByNumber` (client CITY) → `Contacted` |
| `IVR_CITY_Callback_Withdraw` | update, only when changed | Inbound, `CallAcceptDateTime` set, `IVR_Client__c = CITY` | Apex `withdrawByNumber` (client CITY) → `Abandoned` |

## 13. Talk time: `IVR_CITY_Talk_Time`
After-save on VoiceCall create/update, only when changed, `CallEndDateTime` set and the call to or from a CITY number. Scheduled path **2 minutes after `CallEndDateTime`** → Apex sums `VoiceCallRecording.DurationInSeconds` → talk-time field. No recording → leave as is. Fault → keep the message.

## 14. Post-call summary (shared)
Update trigger, `CallAcceptDateTime` set, async-after-commit → get transcript → stop if blank → prompt template → save the summary text after "Summary:" only when it's a real summary. One flow serves every client.

---

## End-to-end test plan (live, inside hours, synthetic numbers)
| # | Scenario | Keys | Expect |
|---|---|---|---|
| 1 | English amount due | 1, 1, 2, account, 1, ZIP, 1 | amount read, 0 → menu |
| 2 | Spanish amount due | 2, 1, 2, … | same in Spanish |
| 3 | Start service happy path | 1, 1, 1, 1, 1, date, 1, ZIP, 1 | "request is in" |
| 4 | Start service, declines deposit | 1, 1, 1, 1, 2 | agent queue |
| 5 | Meter stolen | 1, 1, 5, account, 1, phone, 1, 2, 1, 1 | lock + replacement |
| 6 | Partner transfer | 1, 2 | partner line rings |
| 7 | Programs, none enrolled | 1, 3, …, 9 | agent queue |
| 8 | Agent, English | 1, 9 | EN live queue, transcription on, recording |
| 9 | Agent, Spanish | 2, 9 | ES live queue |
| 10 | Repeat to agent | 1, #, #, #, # | agent queue |
| 11 | Closed hours | 1, 9 after hours | closed message |
| 12 | Callback | 1, 9 with all agents busy, 2, number, 1 | request in callback queue; agent calls back; request `Contacted` |
| 13 | Crew line | dial crew number | crew queue |
| 14 | Post-call | after #8 | recording, talk time after ~2 min, summary |

After each call: VoiceCall disposition, AgentWork, recording count, transcript entry count (flags only, `diagnostics.md`).
