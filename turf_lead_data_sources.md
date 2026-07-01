# Austin Metro Artificial Turf Lead — Data Sources

Scope: Football, soccer, and baseball/softball artificial turf opportunities in the five-county Austin MSA (Travis, Williamson, Hays, Bastrop, Caldwell).

Each source is listed with fields intended for programmatic consumption. `sport_confirmed: false` means listings typically say "athletic fields" / "stadium" without naming a sport, so the lead requires sport validation against the keyword filters listed at the end of this file.

---

## Sources

### SRC-001
- id: SRC-001
- entity: Leander ISD
- entity_type: school_district
- source_type: bond_program
- name: Bond Athletics Projects
- url: https://www.leanderisd.org/bond_athleticsprojects/
- contains: stadium turf replacement, HS baseball/softball turf, MS competition field turf
- relevant_sports: [football, baseball_softball, multipurpose]
- lead_stage: [early_planning, funding, awarded]
- searchability: good
- monitor_frequency: monthly
- sport_confirmed: true

### SRC-002
- id: SRC-002
- entity: Leander ISD
- entity_type: school_district
- source_type: procurement
- name: Purchasing (Bonfire portal)
- url: https://www.leanderisd.org/departments/business-operations/purchasing/
- contains: IFB, RFP, CSP, CMAR solicitations
- relevant_sports: [needs_validation]
- lead_stage: [active_bid]
- searchability: good
- monitor_frequency: weekly
- sport_confirmed: false

### SRC-003
- id: SRC-003
- entity: Round Rock ISD
- entity_type: school_district
- source_type: bond_program
- name: 2024 Bond Tracker
- url: https://bond.roundrockisd.org/
- contains: bond project tracker, turf field replacements
- relevant_sports: [football, multipurpose]
- lead_stage: [funding, active_bid]
- searchability: good
- monitor_frequency: monthly
- sport_confirmed: false

### SRC-004
- id: SRC-004
- entity: Round Rock ISD
- entity_type: school_district
- source_type: procurement
- name: Purchasing / e-bid portal
- url: https://www.roundrockisd.org/departments/purchasing/
- contains: construction and turf bids
- relevant_sports: [needs_validation]
- lead_stage: [active_bid]
- searchability: good
- monitor_frequency: weekly
- sport_confirmed: false

---

## Keyword Filters (for the extraction step)

Apply these against scraped titles/body text. A lead qualifies only if it matches at least one TURF keyword AND at least one SPORT keyword (or an explicit multipurpose field reference).

turf_keywords: ["artificial turf", "synthetic turf", "turf replacement", "turf installation", "field turf", "synthetic surface", "turf field", "field resurfacing", "infield turf", "synthetic infield"]

football_keywords: ["football field", "football stadium", "stadium turf", "practice field", "high school stadium", "football field renovation", "football field replacement"]

soccer_keywords: ["soccer field", "soccer complex", "soccer park", "youth soccer", "soccer field renovation", "soccer field replacement", "football/soccer field"]

baseball_softball_keywords: ["baseball field", "softball field", "baseball complex", "softball complex", "baseball/softball complex", "ballfield", "baseball turf", "softball turf", "baseball field renovation", "softball field renovation"]

procurement_keywords: ["bid", "RFP", "RFQ", "CSP", "competitive sealed proposal", "invitation to bid", "awarded contract", "notice to bidders", "construction services", "CMAR", "vendor registration", "bond", "capital improvement program", "CIP"]

exclusion_keywords: ["basketball", "tennis", "pickleball", "volleyball", "lacrosse", "track only", "pool", "playground", "gym", "trail", "golf", "skate park"]
