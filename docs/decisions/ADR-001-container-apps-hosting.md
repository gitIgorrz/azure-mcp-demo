# ADR-001: Azure Container Apps as the MCP server host

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server must be hosted remotely, reachable over HTTPS (Streamable-HTTP), with a
managed identity attached for secretless Azure auth. Candidates: Container Apps, App Service
(Linux), AKS, VMs.

## Decision

Use **Azure Container Apps** as the compute host for the MCP server.

## Rationale

- **Scale-to-zero**: idle cost approaches zero — critical for a lab on a personal PAYG subscription.
- **Native UAMI support**: first-class user-assigned managed identity attachment; no extra config.
- **VNet-integrable**: workload profiles support VNet injection for the enterprise evolution path.
- **Managed**: no OS patching, no cluster management. Lower ops burden than AKS or VMs.
- **Simple HTTPS ingress**: built-in ingress with TLS termination, no additional load balancer needed for the lab.
- App Service is an acceptable alternative; AKS adds cluster overhead unjustified for one container; VMs are out.

## Consequences

- Container Apps imposes a cold-start latency on scale-from-zero (acceptable for a lab demo).
- Log streaming and diagnostics wire into Log Analytics — covered by the standard diagnostic settings resource.
- VNet injection (enterprise target) requires a Consumption + Dedicated workload profile environment — documented in ADR as the upgrade path, not provisioned in lab.

## Enterprise target

VNet-injected Container Apps environment on a dedicated MCP spoke, internal ingress, private
endpoint + Private DNS zone for internal consumer resolution. See
[docs/background/architecture-intent.md](../background/architecture-intent.md).
