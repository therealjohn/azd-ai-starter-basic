# postprovision.ps1 — Assign agent identity RBAC after azd provision
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

$ErrorActionPreference = "Continue"

# Read azd environment variables
$AI_ACCOUNT_NAME = $env:AZURE_AI_ACCOUNT_NAME
$PROJECT_NAME = $env:AZURE_AI_PROJECT_NAME
$PROJECT_ENDPOINT = $env:AZURE_AI_PROJECT_ENDPOINT
$AI_ACCOUNT_ID = $env:AZURE_AI_ACCOUNT_ID
$APP_INSIGHTS_RID = $env:APPLICATIONINSIGHTS_RESOURCE_ID

# Validate required values
$requiredVars = @{
    "AZURE_AI_ACCOUNT_NAME" = $AI_ACCOUNT_NAME
    "AZURE_AI_PROJECT_NAME" = $PROJECT_NAME
    "AZURE_AI_PROJECT_ENDPOINT" = $PROJECT_ENDPOINT
    "AZURE_AI_ACCOUNT_ID" = $AI_ACCOUNT_ID
}
$missing = @()
foreach ($kv in $requiredVars.GetEnumerator()) {
    if (-not $kv.Value) { $missing += $kv.Key }
}
if ($missing.Count -gt 0) {
    Write-Host "Warning: Missing environment variables: $($missing -join ', ')"
    Write-Host "Agent identity RBAC will not be configured. Run 'azd provision' again or configure manually."
    exit 0
}

Write-Host ""
Write-Host "Post-provision: Agent Identity RBAC"
Write-Host "  AI Account: $AI_ACCOUNT_NAME"
Write-Host "  Project:    $PROJECT_NAME"

# Constants
$AGENTS_API = "v1"
$ROLE_AI_USER = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
$ROLE_MONITORING_PUBLISHER = "3913510d-42f4-4e42-8a64-420c390055eb"

# Helper: assign a role
function Assign-Role {
    param(
        [string]$RoleId,
        [string]$RoleName,
        [string]$Scope,
        [string]$Principal,
        [string]$PrincipalType = "ServicePrincipal"
    )
    $output = az role assignment create `
        --assignee-object-id $Principal `
        --assignee-principal-type $PrincipalType `
        --role $RoleId `
        --scope $Scope 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "    ✓ $RoleName"
    }
    elseif ($output -match "already exists") {
        Write-Host "    ✓ $RoleName (already assigned)"
    }
    else {
        Write-Host "    ✗ $RoleName — $($output | Select-Object -First 2)"
    }
}

# Step 1: Discover or trigger agent identity
Write-Host "[1/2] Discovering agent identity..."

$AGENT_IDENTITY_NAME = "${AI_ACCOUNT_NAME}-${PROJECT_NAME}-AgentIdentity"
$AGENT_IDENTITIES = (az ad sp list --display-name $AGENT_IDENTITY_NAME --query "[].id" -o tsv 2>$null) | Where-Object { $_ }

if ($AGENT_IDENTITIES) {
    Write-Host "  ✓ Agent identity found in Azure AD"
}
else {
    Write-Host "  Agent identity not found — triggering creation via temp Foundry agent..."

    # Get the first model deployment name
    $RESOURCE_GROUP = $env:AZURE_RESOURCE_GROUP
    $MODEL_NAME = az cognitiveservices account deployment list `
        --name $AI_ACCOUNT_NAME `
        --resource-group $RESOURCE_GROUP `
        --query "[0].name" -o tsv 2>$null

    if (-not $MODEL_NAME) {
        Write-Host "  ⚠ No model deployments found — skipping agent identity RBAC."
        Write-Host "    Deploy a model first, then run: azd provision"
        exit 0
    }

    Write-Host "  Using model: $MODEL_NAME"

    # Wait for data-plane endpoint to be reachable
    Write-Host "  Waiting for project data-plane endpoint..."
    $endpointReady = $false
    for ($i = 1; $i -le 18; $i++) {
        $null = az rest --method GET `
            --url "${PROJECT_ENDPOINT}/agents?api-version=${AGENTS_API}" `
            --resource https://ai.azure.com `
            -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $endpointReady = $true
            Write-Host "  ✓ Endpoint is ready"
            break
        }
        Start-Sleep -Seconds 10
    }

    if (-not $endpointReady) {
        Write-Host "  ⚠ Endpoint not reachable after 3 minutes — skipping agent identity RBAC."
        Write-Host "    Wait a few minutes and run: azd provision"
        exit 0
    }

    # Create temp agent to trigger identity creation
    $tempBody = '{"name": "setup-temp", "definition": {"kind": "prompt", "model": "' + $MODEL_NAME + '", "instructions": "Temporary agent for identity provisioning."}}'
    $tmpFile = Join-Path $env:TEMP "postprovision-$(New-Guid).json"
    try {
        $tempBody | Out-File -FilePath $tmpFile -Encoding utf8 -NoNewline
        $TEMP_AGENT_ID = (az rest --method POST `
            --url "${PROJECT_ENDPOINT}/agents?api-version=${AGENTS_API}" `
            --resource https://ai.azure.com `
            --body "@$tmpFile" `
            --query name -o tsv 2>$null)

        if ($LASTEXITCODE -eq 0 -and $TEMP_AGENT_ID) {
            Write-Host "  ✓ Created temp agent: $TEMP_AGENT_ID"
            $null = az rest --method DELETE `
                --url "${PROJECT_ENDPOINT}/agents/${TEMP_AGENT_ID}?api-version=${AGENTS_API}" `
                --resource https://ai.azure.com `
                -o none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Deleted temp agent"
            }
            else {
                Write-Host "  ⚠ Could not delete temp agent (clean up manually)"
            }
        }
        else {
            Write-Host "  ⚠ Could not create temp agent — ensure a model deployment exists and you have Azure AI User role."
        }
    }
    finally {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
    }

    # Poll for agent identity in Azure AD
    Write-Host "  Waiting for agent identity to appear..."
    for ($i = 1; $i -le 6; $i++) {
        $AGENT_IDENTITIES = (az ad sp list --display-name $AGENT_IDENTITY_NAME --query "[].id" -o tsv 2>$null) | Where-Object { $_ }
        if ($AGENT_IDENTITIES) {
            Write-Host "  ✓ Agent identity detected in Azure AD"
            break
        }
        Start-Sleep -Seconds 10
    }

    if (-not $AGENT_IDENTITIES) {
        Write-Host "  ⚠ Agent identity not found yet — the platform can take up to 15 minutes."
        Write-Host "    Wait a few minutes and re-run: azd provision"
        exit 0
    }
}

# Step 2: Assign RBAC to agent identity
Write-Host ""
Write-Host "[2/2] Assigning RBAC to agent identity..."

foreach ($AGENT_OID in ($AGENT_IDENTITIES -split "`n" | Where-Object { $_ })) {
    $AGENT_DISPLAY = az ad sp show --id $AGENT_OID --query displayName -o tsv 2>$null
    Write-Host "  Agent identity: $AGENT_DISPLAY ($AGENT_OID)"
    Assign-Role -RoleId $ROLE_AI_USER -RoleName "Azure AI User → AI account" -Scope $AI_ACCOUNT_ID -Principal $AGENT_OID
    if ($APP_INSIGHTS_RID) {
        Assign-Role -RoleId $ROLE_MONITORING_PUBLISHER -RoleName "Monitoring Metrics Publisher → App Insights" -Scope $APP_INSIGHTS_RID -Principal $AGENT_OID
    }
    else {
        Write-Host "    ⚠ APPLICATIONINSIGHTS_RESOURCE_ID not set — skipping Monitoring Metrics Publisher"
    }
}

Write-Host ""
Write-Host "Done."
