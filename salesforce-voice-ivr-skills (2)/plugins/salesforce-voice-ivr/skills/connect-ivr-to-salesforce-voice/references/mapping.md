# Amazon Connect → Salesforce Voice mapping

| Amazon Connect | Salesforce Voice (Native Voice) |
|---|---|
| Contact flow; Transfer to flow | Routing Flow (`processType` RoutingFlow, input `recordId` = VoiceCall Id) called as a **subflow**; returns `nextStep` (and optionally `menuSelection`) |
| Play prompt | `playPromptAsyncAction`, `promptType=Message` (text-to-speech), `languageValue` (e.g. en-US, es-MX), `voiceProfileValue` (voice set per prompt; no global setting) |
| Get customer input (DTMF) | Same Play Prompt element with `userResponseSettings=true`, `responseValues`, `inputValueLength`, `responseTime`, `interDigitResponseTimeout`; key read from `<Element>.dtmfInput` |
| Retry loops, invalid / timeout branches | Flow counter variables + decisions; `requireResponseRetry=false`; accept all keys; formula `NOT(ISBLANK(key))` separates wrong key from no input |
| SSML `<prosody>`, `<say-as>` | Not supported. Only `<break time="..."/>` and `<phoneme>` (English). Digit read-backs built with formulas |
| Contact attributes | Custom fields on VoiceCall, written with Update Records (each with a fault path that continues the call) |
| Invoke AWS Lambda | Apex `@InvocableMethod` (add `callout=true` when it makes HTTP callouts) |
| Check hours of operation | Business Hours record (by name) + Apex `BusinessHours.isWithin` |
| Set working queue + Transfer to queue | `routeWork`, QueueBased, service channel `sfdc_phone`, queue selected as a **fixed value** |
| Transfer to phone number | `externalTransferAsyncAction` ("Add External Party to Call") with recordId, fromNumber, toNumber; give it a fault path to the queue |
| Set recording and analytics behavior | `disableRecAndTranscription` ("Set Recording and Transcription Behavior"); can only disable / re-enable, not force recording of IVR-only legs |
| Customer queue flow, hold music | Default Salesforce queue music (no in-queue flow set) |
| Disconnect | End the routing flow / End Call |
| Contact Lens transcript and summary | Native transcription of the agent leg + a record-triggered flow calling a prompt template for the AI summary |
| CloudWatch logs | Debug logs on the Platform Integration User (handle as sensitive), flow fault emails, status/error fields on VoiceCall |

## Could not be translated (decide with the business)
- Speech rate (`<prosody rate>`): use `<break>` pauses or a different voice.
- Hold music or hold messages played from a flow: Media prompts have been unreliable; rely on default queue music.
- Interruptible in-queue callback offer: `inQueueFlowAction` ("Set In-Queue Experience") stopped the queue music in testing.
- Recording of IVR-only calls: Native Voice records once an agent joins.
- Transcript language setting: none; speech is transcribed in the language spoken.
- Transcripts on agent click-to-dial outbound calls: platform behaviour, needs a Salesforce case.
- Callback record linking like Connect (Previous/Next contact): not settable on Native Voice.
