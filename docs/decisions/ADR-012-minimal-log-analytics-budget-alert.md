# ADR-012: Minimal Log Analytics retention and Azure Budget alert

**Date:** 2026-06-04
**Status:** Accepted

## Context

Observability (Log Analytics) and cost control (Azure Budget) are needed. Log Analytics
retention and daily cap directly affect monthly cost. This is a personal PAYG lab.

## Decision

- **Log Analytics workspace** (`law-mcp-demo-lab`): minimum retention (31 days — the Azure
  default and minimum). No daily cap set initially, but cost alert will fire before overrun.
- **Azure Budget** (`budget-mcp-demo-lab`): monthly budget threshold **£10** with an alert
  at 80% (£8) and 100% (£10) notifying `igor_111@hotmail.com`.
- **Diagnostic settings**: Container App logs + metrics → Log Analytics workspace.

## Rationale

**Log Analytics retention**: the minimum retention (31 days) is the lowest-cost option and
sufficient for a lab. Each additional day of retention costs money. For a demo server that
may run infrequently, 31 days covers any active investigation window.

**Azure Budget alert**: cost overrun on a personal subscription is a real risk. At scale-to-zero
idle the expected cost is near zero, but misconfiguration (e.g. the Container App not scaling
down, or an unexpected Log Analytics data ingestion spike) could incur charges. A £10/month
budget with dual alerts (80% + 100%) provides early warning with enough headroom to investigate
before material cost is incurred.

**No daily cap on Log Analytics**: a daily cap cuts off log ingestion mid-day if hit, which
can mask incidents. The Budget alert is a more graceful cost control that warns without
breaking observability.

## Consequences

- Budget alerts are notification-only — they do not stop resources. The alert buys time to
  investigate; it does not automatically shut down the deployment.
- If the lab is left running with unexpected traffic, costs could exceed £10. The decommission
  scripts (`scripts/teardown/`) must be used to fully remove resources.
- Log Analytics data beyond 31 days is purged automatically — acceptable for a lab.

## Enterprise target

Longer retention (90+ days for audit), Azure Monitor Private Link Scope (AMPLS) to route
Log Analytics traffic over private endpoints (no public log ingestion endpoint), dedicated
Log Analytics workspace per environment, stricter budget controls per environment subscription.
