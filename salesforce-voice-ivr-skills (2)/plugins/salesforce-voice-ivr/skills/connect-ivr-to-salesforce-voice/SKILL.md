---
name: connect-ivr-to-salesforce-voice
description: Plan a migration of an Amazon Connect IVR (contact flows + AWS Lambdas) to Salesforce Voice / Native Voice (Agentforce Contact Center) routing flows and Apex. TRIGGER when the user shares Amazon Connect contact-flow JSON exports, asks to migrate, convert, rebuild or map a Connect IVR to Salesforce Voice, or wants an inventory, gap list or build plan for such a migration. DO NOT TRIGGER for building or editing individual routing flows (use salesforce-voice-ivr-build) or for testing and deploying them (use salesforce-voice-ivr-test-deploy).
---

# Plan an Amazon Connect → Salesforce Voice IVR migration

Turns Amazon Connect contact-flow exports into an inventory, a mapping, a gap list and an ordered build plan. Read-only: this skill changes nothing in any org.

## Required inputs
- The Connect contact-flow JSON exports (one file per flow), or the folder holding them.
- The list of Lambda functions the flows call, with what each one does (ask if not supplied).
- The target org alias (`sf org display -o <alias>`), only to check what already exists.

## Workflow
1. **Inventory the exports.** For every contact flow list: entry point, each Play prompt / Get customer input (text, language, voice, keys accepted, timeout), each branch, every Lambda invoke (function name, parameters, attributes it sets), every Set attribute, queue transfer, phone transfer, hours check, recording setting and disconnect. Count prompts per language.
2. **Draw the call chain** (Mermaid flowchart) from the entry number to every end: self-service ends, transfers, agent queues, closed-hours message.
3. **Map each piece** using `references/mapping.md`. Every Connect block must land in one row; anything that doesn't is a gap.
4. **List the gaps** using the "Could not be translated" section of `references/mapping.md`. For each gap propose the closest Salesforce behaviour and flag it for a business decision.
5. **Note bugs in the source flows** (wrong prompt on a branch, typos, dead ends) and ask whether to copy or fix them. Do not silently copy them.
6. **Design the subflow split:** entry flow → language main menus → one feature flow per self-service function → one queue-transfer flow that every agent path ends in. Define the `nextStep` contract (`END` | `MAIN_MENU` | `AGENT`).
7. **Plan the Apex layer:** one invocable class per Lambda (or per back-end operation family). Keep request/response shapes close to the Lambda's. Name labels `IVR: <Action>`.
8. **Plan the data written to the Voice Call** (replaces contact attributes): language, menu selection (`code|label`), per-feature status and error fields.
9. **Write the build order** (see `references/build-order.md`) and the list of org setup done by hand.
10. **Deliver** a single Markdown plan: inventory table, call-chain diagram, mapping, gaps with proposals, flow list with purpose, Apex list, fields, build order, manual setup, test plan outline.

## Rules
| Rule | Why |
|---|---|
| No caller or customer data in the plan; synthetic examples only (e.g. +1 202-555-0100) | Exports and logs can contain real numbers and names |
| Never copy secrets found in exports or Lambda config into the plan; flag them for rotation | Plans get shared |
| Present gaps and source-flow bugs as decisions for the user, not as done deals | The business owns caller experience |
| Read-only: no deploys, no record changes | Planning skill only |

## Reference files
| File | When to read |
|---|---|
| `references/mapping.md` | Step 3–4: Connect block → Salesforce element, and what can't be translated |
| `references/build-order.md` | Step 9: deploy order and manual setup |
