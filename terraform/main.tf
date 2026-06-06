# =============================================================================
# azure-mcp-demo — Terraform infrastructure
#
# Ownership model
# ---------------
#   Terraform owns:  resource group, UAMI, Log Analytics, Container App
#                    environment + app, diagnostics, budget.
#   Manual script:   Reader role assignment on the UAMI (requires User Access
#                    Administrator; outside the Contributor scope of the CI
#                    identity). Run scripts/manual-uami-rbac.sh after the
#                    first apply that creates the RG + UAMI.
#
# First-apply order
# -----------------
#   1. terraform apply          — creates RG, UAMI, Log Analytics, and the
#                                  Container App environment.
#   2. scripts/manual-uami-rbac.sh  — assigns Reader to the UAMI at RG scope.
#   3. terraform apply (again)  — creates the Container App (which pulls the
#                                  image and starts with auth env vars).
#
# Naming and tags follow CLAUDE.md conventions (section: Naming & tagging).
# =============================================================================

# ---------------------------------------------------------------------------
# Locals — computed naming and shared tag block
# ---------------------------------------------------------------------------

locals {
  rg_name     = "rg-mcp-demo-${var.environment}"
  uami_name   = "id-mcp-demo-${var.environment}"
  law_name    = "law-mcp-demo-${var.environment}"
  cae_name    = "cae-mcp-demo-${var.environment}"
  ca_name     = "ca-mcp-demo-${var.environment}"
  budget_name = "budget-mcp-demo-${var.environment}"

  tags = {
    environment = var.environment
    project     = "azure-mcp-demo"
    managed-by  = "terraform"
    repo        = "gitIgorrz/azure-mcp-demo"
    cost-centre = "lab"
  }
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# User-assigned managed identity (runtime identity for the MCP server)
#
# Terraform creates the UAMI; the Reader role assignment is performed
# separately by scripts/manual-uami-rbac.sh (requires User Access Admin).
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "uami" {
  name                = local.uami_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Log Analytics workspace (minimum retention — cost-conscious lab)
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "law" {
  name                = local.law_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Container App environment
# ---------------------------------------------------------------------------

resource "azurerm_container_app_environment" "cae" {
  name                       = local.cae_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  tags                       = local.tags
}

# ---------------------------------------------------------------------------
# Container App — MCP server
# ---------------------------------------------------------------------------

resource "azurerm_container_app" "ca" {
  name                         = local.ca_name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  tags                         = local.tags

  # Attach the UAMI so DefaultAzureCredential picks it up without a secret.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.uami.id]
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "mcp-server"
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"

      # --- Auth config (identifiers, not secrets) ---
      env {
        name  = "MCP_TENANT_ID"
        value = var.mcp_tenant_id
      }
      env {
        name  = "MCP_AUDIENCE"
        value = var.mcp_audience
      }

      # --- Azure SDK config ---
      env {
        name  = "AZURE_SUBSCRIPTION_ID"
        value = var.subscription_id
      }
      # Tell DefaultAzureCredential which UAMI to use when multiple identities
      # are attached to the container (good hygiene even with only one identity).
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.uami.client_id
      }

      # --- Optional caller allow-list (omit env var when empty to keep defaults) ---
      dynamic "env" {
        for_each = var.mcp_allowed_app_ids != "" ? [var.mcp_allowed_app_ids] : []
        content {
          name  = "MCP_ALLOWED_APP_IDS"
          value = env.value
        }
      }

      # Liveness probe — unauthenticated /health endpoint (exempt from JWT auth).
      liveness_probe {
        transport               = "HTTP"
        path                    = "/health"
        port                    = 8080
        initial_delay           = 10
        interval_seconds        = 30
        timeout                 = 10
        failure_count_threshold = 3
      }

      # Readiness probe — same path; gates traffic until the server is up.
      readiness_probe {
        transport               = "HTTP"
        path                    = "/health"
        port                    = 8080
        initial_delay           = 5
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "http"
    # HTTPS-only (CLAUDE.md guardrail 6). This is the azurerm default, set
    # explicitly so the posture is auditable and checkov CKV_AZURE_140 can see it:
    # plain-HTTP requests to the public FQDN are redirected to HTTPS.
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ---------------------------------------------------------------------------
# Diagnostics — Container App → Log Analytics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "ca_diag" {
  name                       = "diag-${local.ca_name}"
  target_resource_id         = azurerm_container_app.ca.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  # Container Apps expose only metrics at the app level (no log categories/groups);
  # the app's console/system logs reach Log Analytics via the Container App Environment.
  metric {
    category = "AllMetrics"
  }
}

# Container App Environment metrics. Console/system logs already flow to Log
# Analytics via azurerm_container_app_environment.log_analytics_workspace_id, so
# routing them again here would double-ingest — metrics only. (The environment
# supports no diagnostic category groups, only specific categories, per the API.)
resource "azurerm_monitor_diagnostic_setting" "cae_diag" {
  name                       = "diag-${local.cae_name}"
  target_resource_id         = azurerm_container_app_environment.cae.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Budget + alert (resource-group scope)
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_resource_group" "budget" {
  name              = local.budget_name
  resource_group_id = azurerm_resource_group.rg.id

  amount     = var.budget_amount_usd
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  # Notify when actual spend exceeds 80% of the monthly limit.
  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.budget_notification_email]
  }

  # Secondary: forecast alert at 100% so there is advance warning.
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.budget_notification_email]
  }
}
