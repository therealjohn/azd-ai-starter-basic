#!/usr/bin/env bash
# postprovision.sh — Assign agent identity RBAC after azd provision
#
# Foundry agents run under a platform-managed Entra service principal called
# the "agent identity". It only exists once an agent has been created in the
# project, and azd doesn't provision it automatically.
#
# This script:
#   1. Looks for the agent identity in Azure AD.
#   2. If missing, creates (then deletes) a throwaway Foundry agent to force
#      the platform to provision the identity.
#   3. Assigns two RBAC roles to that identity:
#        • Azure AI User          – on the AI account (lets agents call models)
#        • Monitoring Metrics Publisher – on App Insights (lets agents emit telemetry)
#
# End result: the agent identity exists and has the permissions it needs to
# run deployed containers. Safe to re-run — existing role assignments are
# detected and skipped.
set -euo pipefail

# Read azd environment variables
AI_ACCOUNT_NAME="${AZURE_AI_ACCOUNT_NAME:-}"
PROJECT_NAME="${AZURE_AI_PROJECT_NAME:-}"
PROJECT_ENDPOINT="${AZURE_AI_PROJECT_ENDPOINT:-}"
AI_ACCOUNT_ID="${AZURE_AI_ACCOUNT_ID:-}"
APP_INSIGHTS_RID="${APPLICATIONINSIGHTS_RESOURCE_ID:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

# Validate required values
MISSING=""
for var in AI_ACCOUNT_NAME PROJECT_NAME PROJECT_ENDPOINT AI_ACCOUNT_ID; do
    if [[ -z "${!var}" ]]; then
        MISSING="$MISSING $var"
    fi
done
if [[ -n "$MISSING" ]]; then
    echo "Warning: Missing environment variables:$MISSING"
    echo "Agent identity RBAC will not be configured. Run 'azd provision' again or configure manually."
    exit 0
fi

echo "Post-provision: Agent Identity RBAC"
echo "  AI Account: $AI_ACCOUNT_NAME"
echo "  Project:    $PROJECT_NAME"

# Constants
AGENTS_API="v1"
ROLE_AI_USER="53ca6127-db72-4b80-b1b0-d745d6d5456d"
ROLE_MONITORING_PUBLISHER="3913510d-42f4-4e42-8a64-420c390055eb"

# Helper: assign a role
assign_role() {
    local role_id="$1" role_name="$2" scope="$3" principal="$4" principal_type="${5:-ServicePrincipal}"
    output=$(az role assignment create \
        --assignee-object-id "$principal" \
        --assignee-principal-type "$principal_type" \
        --role "$role_id" \
        --scope "$scope" 2>&1) && {
        echo "    ✓ $role_name"
    } || {
        if echo "$output" | grep -q "already exists"; then
            echo "    ✓ $role_name (already assigned)"
        else
            echo "    ✗ $role_name — $(echo "$output" | head -2)"
        fi
    }
}

# Step 1: Discover or trigger agent identity
echo "[1/2] Discovering agent identity..."

AGENT_IDENTITY_NAME="${AI_ACCOUNT_NAME}-${PROJECT_NAME}-AgentIdentity"
AGENT_IDENTITIES=$(az ad sp list --display-name "$AGENT_IDENTITY_NAME" --query "[].id" -o tsv 2>/dev/null || true)

if [[ -n "$AGENT_IDENTITIES" ]]; then
    echo "  ✓ Agent identity found in Azure AD"
else
    echo "  Agent identity not found — triggering creation via temp Foundry agent..."

    MODEL_NAME=$(az cognitiveservices account deployment list \
        --name "$AI_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "[0].name" -o tsv 2>/dev/null || true)

    if [[ -z "$MODEL_NAME" ]]; then
        echo "  ⚠ No model deployments found — skipping agent identity RBAC."
        echo "    Deploy a model first, then run: azd provision"
        exit 0
    fi

    echo "  Using model: $MODEL_NAME"

    # Wait for data-plane endpoint to be reachable
    echo "  Waiting for project data-plane endpoint..."
    ENDPOINT_READY=false
    for i in $(seq 1 18); do
        if az rest --method GET \
            --url "${PROJECT_ENDPOINT}/agents?api-version=${AGENTS_API}" \
            --resource https://ai.azure.com \
            -o none 2>/dev/null; then
            ENDPOINT_READY=true
            echo "  ✓ Endpoint is ready"
            break
        fi
        sleep 10
    done

    if [[ "$ENDPOINT_READY" != "true" ]]; then
        echo "  ⚠ Endpoint not reachable after 3 minutes — skipping agent identity RBAC."
        echo "    Wait a few minutes and run: azd provision"
        exit 0
    fi

    # Create temp agent to trigger identity creation
    TEMP_AGENT_ID=$(az rest --method POST \
        --url "${PROJECT_ENDPOINT}/agents?api-version=${AGENTS_API}" \
        --resource https://ai.azure.com \
        --headers "Content-Type=application/json" \
        --body '{"name": "setup-temp", "definition": {"kind": "prompt", "model": "'"$MODEL_NAME"'", "instructions": "Temporary agent for identity provisioning."}}' \
        --query name -o tsv 2>/dev/null) && {
        echo "  ✓ Created temp agent: $TEMP_AGENT_ID"
        az rest --method DELETE \
            --url "${PROJECT_ENDPOINT}/agents/${TEMP_AGENT_ID}?api-version=${AGENTS_API}" \
            --resource https://ai.azure.com \
            -o none 2>/dev/null && echo "  ✓ Deleted temp agent" || echo "  ⚠ Could not delete temp agent (clean up manually)"
    } || {
        echo "  ⚠ Could not create temp agent — ensure a model deployment exists and you have Azure AI User role."
    }

    # Poll for agent identity to appear in Azure AD
    echo "  Waiting for agent identity to appear..."
    for i in $(seq 1 6); do
        AGENT_IDENTITIES=$(az ad sp list --display-name "$AGENT_IDENTITY_NAME" --query "[].id" -o tsv 2>/dev/null || true)
        if [[ -n "$AGENT_IDENTITIES" ]]; then
            echo "  ✓ Agent identity detected in Azure AD"
            break
        fi
        sleep 10
    done

    if [[ -z "$AGENT_IDENTITIES" ]]; then
        echo "  ⚠ Agent identity not found yet — the platform can take up to 15 minutes."
        echo "    Wait a few minutes and re-run: azd provision"
        exit 0
    fi
fi

# Step 2: Assign RBAC to agent identity
echo "[2/2] Assigning RBAC to agent identity..."

for AGENT_OID in $AGENT_IDENTITIES; do
    AGENT_DISPLAY=$(az ad sp show --id "$AGENT_OID" --query displayName -o tsv 2>/dev/null || echo "unknown")
    echo "  Agent identity: $AGENT_DISPLAY ($AGENT_OID)"
    assign_role "$ROLE_AI_USER" "Azure AI User → AI account" "$AI_ACCOUNT_ID" "$AGENT_OID"
    if [[ -n "$APP_INSIGHTS_RID" ]]; then
        assign_role "$ROLE_MONITORING_PUBLISHER" "Monitoring Metrics Publisher → App Insights" "$APP_INSIGHTS_RID" "$AGENT_OID"
    else
        echo "    ⚠ APPLICATIONINSIGHTS_RESOURCE_ID not set — skipping Monitoring Metrics Publisher"
    fi
done

echo "Done."
