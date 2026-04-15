# Menu UX Audit

This document defines how to evaluate the interactive menu UX before changing it.

The goal is to make menu-driven work predictable for a non-expert operator:
- no hidden steps
- no misleading choices
- no internal terminology unless it is necessary
- no dead ends without a clear way back

## Scope

Primary user-facing menu sections:
- `Sites`
- `SSL`
- `PHP`
- `Database`
- `Diagnostics`
- `Logs`
- `Backup / Migrate`
- `Applications`
- `Profiles`
- `System`

Priority flows:
1. `Sites -> Create site`
2. `System -> Update simai-env`
3. `Applications` shared daily-ops flow
4. `SSL` issuance/status
5. `Site info` / `Site doctor`

## UX quality gate

Each flow is scored on the criteria below.

Score each criterion:
- `2` = good
- `1` = acceptable but confusing
- `0` = poor / misleading / broken

### Criteria

1. **Discoverability**
- Can a normal operator understand where to go next from the menu labels alone?

2. **Prompt clarity**
- Does each question use plain language?
- Does the operator understand why the system is asking this?

3. **Choice quality**
- Are only realistic choices shown?
- Are unavailable options hidden or clearly marked?

4. **Cancellation safety**
- Can the operator back out safely at every step?
- Does cancel avoid partial or misleading state?

5. **Flow continuity**
- Does the command progress in a sensible order?
- Are there any surprising jumps, repeated questions, or context switches?

6. **Outcome clarity**
- After the command ends, is it obvious what was created or changed?
- Is the next recommended action clear?

7. **Terminology**
- Is the language user-facing rather than implementation-facing?
- Are engineering terms shown only when genuinely needed?

### Rating bands

- `12-14`: good, can stay as-is
- `9-11`: usable, should be polished
- `6-8`: confusing, needs redesign
- `0-5`: unacceptable, should not ship

## Scenario format

Each audited scenario should be documented with:

1. Entry point
- exact menu path

2. Expected operator goal
- what the user thinks they are doing

3. Actual prompt sequence
- what the menu really asks

4. Confusion points
- where the user hesitates or gets surprised

5. Recommended change
- smallest safe improvement first

6. Re-test result
- before/after score

## Core scenarios

### Scenario A. Create a standard CMS site

Path:
- `Sites -> Create site`

Goal:
- create a new site with a chosen profile, DB, PHP, and HTTPS

Minimum expected flow:
1. domain
2. profile
3. activity class
4. PHP version
5. HTTPS yes/no
6. DB yes/no when needed
7. summary + next steps

Current known risks:
- hidden defaults
- profile-specific surprises
- too many technical prompts

### Scenario B. Finish a CMS install

Paths:
- `Applications -> WordPress complete setup`
- `Applications -> Bitrix complete setup`
- `Applications -> Laravel complete setup`

Goal:
- complete setup after web installer or bootstrap work

Minimum expected flow:
1. choose site
2. apply the expected completion step
3. show clear next steps

### Scenario C. Issue HTTPS

Paths:
- `SSL -> Issue Let's Encrypt`
- or inline during `Sites -> Create site`

Goal:
- enable HTTPS without understanding certbot internals

Minimum expected flow:
1. choose site/domain
2. confirm email if needed
3. summary + validation path

### Scenario D. Inspect and diagnose a site

Paths:
- `Sites -> Site info`
- `Diagnostics -> Site doctor`
- `SSL -> SSL status`

Goal:
- understand whether the site is healthy and what to do next

### Scenario E. Pause and resume a site

Paths:
- `Sites -> Pause site`
- `Sites -> Resume site`

Goal:
- safely stop and restore a low-traffic site

## Work plan

Use this order for UX work:

1. Fix flows scoring `0-8`
2. Then fix misleading labels
3. Then simplify repeated prompts
4. Then improve summaries and next steps
5. Then sync docs

## Current priority order

1. `Sites -> Create site`
2. `Applications` section structure
3. `SSL` issuance flow
4. `System` everyday actions
5. remaining menu polish

## Notes for review

When reviewing a flow, ask:
- Would a first-time operator understand this without docs?
- Does the menu ask about the right thing at the right time?
- Is the operator forced to know an implementation detail?
- Is there a safe cancel path?
- After success, is the next action obvious?
