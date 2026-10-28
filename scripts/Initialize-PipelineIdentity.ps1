<#
.SYNOPSIS
  Creates the Azure and Microsoft Entra ID setup for the azure-bicep-cicd-pipeline GitHub Actions workflows:
  two resource groups, a custom role, three app registrations with OIDC federated credentials (no secrets),
  and resource-group-scoped role assignments.
.DESCRIPTION
  Run one step at a time with -Step, or all steps with -Step All.
  Idempotent: each step checks what already exists and creates only what's missing, so re-running is safe.
  Output contains names, roles, and scopes only. No subscription, tenant, client, or object IDs are printed,
  so the -OutFile log can be committed as evidence after the usual leak check.

  Steps:
    1  Resource groups rg-cicd-dev, rg-cicd-prod
    2  Custom role "Bicep What-If Reader" (from identity/bicep-whatif-reader.role.json)
    3  App registrations + service principals (no secrets)
    4  Federated credentials (GitHub OIDC trust)
    5  Role assignments at resource-group scope
    6  Verify (read-only): secrets, federated credentials, role assignments, role scopes
.EXAMPLE
  .\scripts\Initialize-PipelineIdentity.ps1 -Step 1 -OutFile docs\evidence\m1-01-resource-groups.txt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('1', '2', '3', '4', '5', '6', 'All')]
  [string]$Step,

  [Parameter(Mandatory)]
  [string]$OutFile,

  [string]$Repo = 'ChefBoyRJeff/azure-bicep-cicd-pipeline',
  [string]$Location = 'eastus',
  [string]$RoleFile = (Join-Path $PSScriptRoot '..\identity\bicep-whatif-reader.role.json')
)

$ErrorActionPreference = 'Stop'

# --- Design (single source of truth for this script) ------------------------------------------
$ResourceGroups = @('rg-cicd-dev', 'rg-cicd-prod')
$CustomRoleName = 'Bicep What-If Reader'

$Identities = @(
  @{ Name = 'gh-cicd-plan';        CredName = 'github-pull-request'; Subject = "repo:${Repo}:pull_request" }
  @{ Name = 'gh-cicd-deploy-dev';  CredName = 'github-env-dev';      Subject = "repo:${Repo}:environment:dev" }
  @{ Name = 'gh-cicd-deploy-prod'; CredName = 'github-env-prod';     Subject = "repo:${Repo}:environment:prod" }
)

$Assignments = @(
  @{ Identity = 'gh-cicd-plan';        Role = $CustomRoleName; ResourceGroup = 'rg-cicd-dev' }
  @{ Identity = 'gh-cicd-plan';        Role = $CustomRoleName; ResourceGroup = 'rg-cicd-prod' }
  @{ Identity = 'gh-cicd-deploy-dev';  Role = 'Contributor';   ResourceGroup = 'rg-cicd-dev' }
  @{ Identity = 'gh-cicd-deploy-prod'; Role = 'Contributor';   ResourceGroup = 'rg-cicd-prod' }
)

# --- Helpers ----------------------------------------------------------------------------------
function Log([string]$Message) { $Message | Tee-Object -FilePath $OutFile -Append }

# Runs az and stops on a non-zero exit code (PowerShell doesn't treat native exit codes as errors by default).
function Invoke-Az {
  $output = & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed with exit code $LASTEXITCODE" }
  return $output
}

# Writes JSON to a temp file without a BOM (az can't parse a BOM) and returns the path for --parameters @file.
function New-TempJson([string]$Json) {
  $path = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($path, $Json)
  return $path
}

function Get-AppId([string]$DisplayName) {
  $ids = @(Invoke-Az ad app list --display-name $DisplayName --query '[].appId' -o tsv | Where-Object { $_ })
  if ($ids.Count -gt 1) { throw "More than one app registration is named '$DisplayName'. Resolve this in the portal first." }
  return $ids | Select-Object -First 1
}

function Get-SpObjectId([string]$AppId) {
  return Invoke-Az ad sp list --filter "appId eq '$AppId'" --query '[0].id' -o tsv
}

$SubscriptionId = Invoke-Az account show --query id -o tsv
$SubscriptionName = Invoke-Az account show --query name -o tsv
function Get-RgScope([string]$Name) { "/subscriptions/$SubscriptionId/resourceGroups/$Name" }

# --- Steps ------------------------------------------------------------------------------------
function Step1-ResourceGroups {
  Log '=== Step 1: resource groups ==='
  foreach ($rg in $ResourceGroups) {
    $envName = $rg -replace '^rg-cicd-', ''
    $exists = Invoke-Az group exists -n $rg
    if ($exists -eq 'true') { Log "  exists   $rg"; continue }
    Invoke-Az group create -n $rg -l $Location --tags project=azure-bicep-cicd-pipeline "environment=$envName" owner=jeff costCenter=CC-1001 managedBy=github-actions -o none
    Log "  created  $rg ($Location)"
  }
}

function Step2-CustomRole {
  Log "=== Step 2: custom role '$CustomRoleName' ==="
  $found = Invoke-Az role definition list --custom-role-only true --name $CustomRoleName --scope (Get-RgScope 'rg-cicd-dev') --query '[].roleName' -o tsv
  if ($found) { Log '  exists   (no change made)'; return }
  $json = (Get-Content $RoleFile -Raw).Replace('{subscriptionId}', $SubscriptionId)
  $tmp = New-TempJson $json
  try { Invoke-Az role definition create --role-definition "@$tmp" -o none }
  finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  Log '  created  (assignable at rg-cicd-dev and rg-cicd-prod only)'
}

function Step3-AppRegistrations {
  Log '=== Step 3: app registrations and service principals (no secrets) ==='
  foreach ($id in $Identities) {
    $appId = Get-AppId $id.Name
    if ($appId) { Log "  exists   app $($id.Name)" }
    else {
      $appId = Invoke-Az ad app create --display-name $id.Name --query appId -o tsv
      Log "  created  app $($id.Name)"
    }
    if (Get-SpObjectId $appId) { Log "  exists   service principal $($id.Name)" }
    else {
      Invoke-Az ad sp create --id $appId -o none
      Log "  created  service principal $($id.Name)"
    }
  }
}

function Step4-FederatedCredentials {
  Log '=== Step 4: federated credentials (GitHub OIDC) ==='
  foreach ($id in $Identities) {
    $appId = Get-AppId $id.Name
    if (-not $appId) { throw "App $($id.Name) not found. Run step 3 first." }
    $subjects = @(Invoke-Az ad app federated-credential list --id $appId --query '[].subject' -o tsv)
    if ($subjects -contains $id.Subject) { Log "  exists   $($id.Name)  <-  $($id.Subject)"; continue }
    $body = @{
      name        = $id.CredName
      issuer      = 'https://token.actions.githubusercontent.com'
      subject     = $id.Subject
      description = "GitHub Actions OIDC for $Repo"
      audiences   = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $tmp = New-TempJson $body
    try { Invoke-Az ad app federated-credential create --id $appId --parameters "@$tmp" -o none }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    Log "  created  $($id.Name)  <-  $($id.Subject)"
  }
}

function Step5-RoleAssignments {
  Log '=== Step 5: role assignments (resource-group scope only) ==='
  foreach ($a in $Assignments) {
    $appId = Get-AppId $a.Identity
    if (-not $appId) { throw "App $($a.Identity) not found. Run step 3 first." }
    $spId = Get-SpObjectId $appId
    $scope = Get-RgScope $a.ResourceGroup
    # Count in PowerShell: a JMESPath function such as length(@) breaks cmd.exe parsing of az.cmd on Windows.
    $count = @((Invoke-Az role assignment list --assignee $spId --role $a.Role --scope $scope -o json) -join "`n" | ConvertFrom-Json).Count
    if ($count -gt 0) { Log "  exists   $($a.Identity)  ->  $($a.Role) @ $($a.ResourceGroup)"; continue }

    # A new service principal or custom role can take a minute to replicate. Retry instead of failing.
    for ($try = 1; $try -le 6; $try++) {
      & az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal --role $a.Role --scope $scope -o none 2>$null
      if ($LASTEXITCODE -eq 0) { break }
      if ($try -eq 6) { throw "Role assignment failed after 6 attempts: $($a.Identity) -> $($a.Role) @ $($a.ResourceGroup)" }
      Log "  waiting  for replication (attempt $try of 6)..."
      Start-Sleep -Seconds 15
    }
    Log "  created  $($a.Identity)  ->  $($a.Role) @ $($a.ResourceGroup)"
  }
}

function Step6-Verify {
  Log '=== Step 6: verification (read-only) ==='
  Log '--- Secrets and certificates per app (expect 0 and 0) ---'
  foreach ($id in $Identities) {
    $appId = Get-AppId $id.Name
    $secrets = @((Invoke-Az ad app credential list --id $appId -o json) -join "`n" | ConvertFrom-Json).Count
    $certs = @((Invoke-Az ad app credential list --id $appId --cert -o json) -join "`n" | ConvertFrom-Json).Count
    Log ("  {0,-20} secrets={1}  certificates={2}" -f $id.Name, $secrets, $certs)
  }
  Log '--- Federated credentials (issuer | subject | audience) ---'
  foreach ($id in $Identities) {
    $appId = Get-AppId $id.Name
    $creds = (Invoke-Az ad app federated-credential list --id $appId -o json) -join "`n" | ConvertFrom-Json
    foreach ($c in $creds) { Log ("  {0,-20} {1} | {2} | {3}" -f $id.Name, $c.issuer, $c.subject, ($c.audiences -join ',')) }
  }
  Log '--- Role assignments for each identity, all scopes (expect resource groups only) ---'
  foreach ($id in $Identities) {
    $spId = Get-SpObjectId (Get-AppId $id.Name)
    $list = (Invoke-Az role assignment list --assignee $spId --all -o json) -join "`n" | ConvertFrom-Json
    if (-not $list) { Log "  $($id.Name): (none)" }
    foreach ($r in $list) {
      $scopeName = if ($r.scope -match '/resourceGroups/([^/]+)$') { "resource group $($Matches[1])" }
                   elseif ($r.scope -match '^/subscriptions/[^/]+$') { 'SUBSCRIPTION (unexpected)' }
                   else { 'other scope (unexpected)' }
      Log ("  {0,-20} {1,-22} @ {2}" -f $id.Name, $r.roleDefinitionName, $scopeName)
    }
  }
  Log "--- Custom role '$CustomRoleName' ---"
  $role = ((Invoke-Az role definition list --custom-role-only true --name $CustomRoleName --scope (Get-RgScope 'rg-cicd-dev') -o json) -join "`n" | ConvertFrom-Json) | Select-Object -First 1
  Log ('  actions: ' + ($role.permissions.actions -join ', '))
  Log ('  assignable scopes: ' + (($role.assignableScopes | ForEach-Object { ($_ -split '/')[-1] }) -join ', '))
}

# --- Run --------------------------------------------------------------------------------------
"Initialize-PipelineIdentity step $Step, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local, subscription '$SubscriptionName', repo $Repo" | Set-Content $OutFile

switch ($Step) {
  '1' { Step1-ResourceGroups }
  '2' { Step2-CustomRole }
  '3' { Step3-AppRegistrations }
  '4' { Step4-FederatedCredentials }
  '5' { Step5-RoleAssignments }
  '6' { Step6-Verify }
  'All' { Step1-ResourceGroups; Step2-CustomRole; Step3-AppRegistrations; Step4-FederatedCredentials; Step5-RoleAssignments; Step6-Verify }
}
Log 'Done.'
