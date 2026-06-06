# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Passed to the provider and to the Container App as AZURE_SUBSCRIPTION_ID."
  type        = string
}

variable "environment" {
  description = "Deployment environment label used in resource names and tags (lab | int | prod)."
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "int", "prod"], var.environment)
    error_message = "environment must be one of: lab, int, prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "australiaeast"
}

# ---------------------------------------------------------------------------
# MCP server auth — passed to the container as plain env vars (not secrets).
# Tenant ID and audience are identifiers, not credentials.
# ---------------------------------------------------------------------------

variable "mcp_tenant_id" {
  description = "Entra tenant GUID. Passed to the container as MCP_TENANT_ID (ADR-006)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mcp_tenant_id))
    error_message = "mcp_tenant_id must be a valid GUID."
  }
}

variable "mcp_audience" {
  description = "Expected JWT audience (aud claim). Comma-separated for multiple values. Passed as MCP_AUDIENCE."
  type        = string
}

variable "mcp_allowed_app_ids" {
  description = "Optional comma-separated caller app-ID allow-list (azp/appid). Empty disables the allow-list. Passed as MCP_ALLOWED_APP_IDS."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Container image
# ---------------------------------------------------------------------------

variable "container_image" {
  description = "Fully-qualified GHCR image reference including @sha256 digest. Example: ghcr.io/gitigorrz/azure-mcp-demo@sha256:<digest>. Set in the HCP workspace variable or CI pipeline; never hardcoded here."
  type        = string
}

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------

variable "budget_amount_usd" {
  description = "Monthly budget limit in USD. A notification fires at 80% of this amount."
  type        = number
  default     = 10
}

variable "budget_notification_email" {
  description = "Email address to notify when the budget threshold is reached."
  type        = string
}

variable "budget_start_date" {
  description = "Budget period start date in RFC3339 format (e.g. 2026-06-01T00:00:00Z). Update to the current month when creating a new workspace."
  type        = string
  default     = "2026-06-01T00:00:00Z"
}
