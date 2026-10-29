<#
.SYNOPSIS
  Pre-merge check for the network design in a .bicepparam file: every subnet must sit inside the VNet address
  space, and no two subnets may overlap.
.DESCRIPTION
  M4b found that an overlapping subnet passes lint, type checks, and what-if, and is only rejected by the network
  provider at deploy time (NetcfgSubnetRangesOverlap). This test moves that rule to the pull request, before anything
  reaches Azure. It needs no Azure access: it compiles the parameter file with Bicep and checks the CIDR math.

  Runs the same way locally (Windows PowerShell 7) and in CI (pwsh on the Ubuntu runner).
  Exit code 0 = valid, 1 = a rule failed.
.EXAMPLE
  ./scripts/Test-SubnetLayout.ps1 -ParamFile infra/params/dev.bicepparam
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string[]]$ParamFile
)

$ErrorActionPreference = 'Stop'

# Parses "a.b.c.d/n" into the network's first and last address as unsigned 32-bit integers.
function ConvertTo-Range([string]$Cidr) {
  if ($Cidr -notmatch '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') { throw "Not an IPv4 CIDR: '$Cidr'" }
  $prefix = [int]$Matches[3]
  if ($prefix -gt 32) { throw "Prefix length out of range: '$Cidr'" }
  $bytes = ([System.Net.IPAddress]::Parse($Matches[1])).GetAddressBytes()
  [Array]::Reverse($bytes)                                   # network byte order -> little-endian for BitConverter
  $ip = [BitConverter]::ToUInt32($bytes, 0)
  $size = [uint64][Math]::Pow(2, 32 - $prefix)
  $first = [uint64]($ip - ($ip % $size))                     # normalize to the network address
  if ($first -ne $ip) { throw "'$Cidr' is not a network address (host bits set; did you mean $(ConvertTo-Cidr $first $prefix)?)" }
  [pscustomobject]@{ Cidr = $Cidr; First = $first; Last = $first + $size - 1 }
}

function ConvertTo-Cidr([uint64]$Value, [int]$Prefix) {
  $b = [BitConverter]::GetBytes([uint32]$Value); [Array]::Reverse($b)
  "$(([System.Net.IPAddress]::new($b)).ToString())/$Prefix"
}

$failed = $false
foreach ($file in $ParamFile) {
  Write-Output "=== $file ==="
  $fileFailed = $false
  $raw = (& az bicep build-params --file $file --stdout) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "az bicep build-params failed for $file" }
  $compiled = $raw | ConvertFrom-Json
  # The Bicep CLI wraps the parameters in "parametersJson" (a JSON string); handle both shapes.
  $params = if ($compiled.parametersJson) { ($compiled.parametersJson | ConvertFrom-Json).parameters } else { $compiled.parameters }

  $vnet = ConvertTo-Range $params.addressSpace.value
  $subnets = @($params.subnets.value | ForEach-Object { $r = ConvertTo-Range $_.addressPrefix; $r | Add-Member Name $_.name -PassThru })
  Write-Output "  VNet $($vnet.Cidr); subnets: $(($subnets | ForEach-Object { "$($_.Name) $($_.Cidr)" }) -join ', ')"

  foreach ($s in $subnets) {
    if ($s.First -lt $vnet.First -or $s.Last -gt $vnet.Last) {
      Write-Output "  FAIL  $($s.Name) $($s.Cidr) is outside the VNet address space $($vnet.Cidr)"; $fileFailed = $true
    }
  }
  for ($i = 0; $i -lt $subnets.Count; $i++) {
    for ($j = $i + 1; $j -lt $subnets.Count; $j++) {
      $a = $subnets[$i]; $b = $subnets[$j]
      if ($a.First -le $b.Last -and $b.First -le $a.Last) {
        Write-Output "  FAIL  $($a.Name) $($a.Cidr) overlaps $($b.Name) $($b.Cidr)"; $fileFailed = $true
      }
    }
  }
  if ($fileFailed) { $failed = $true } else { Write-Output '  PASS  all subnets inside the VNet, no overlaps' }
}

if ($failed) { Write-Output 'Subnet layout check FAILED.'; exit 1 }
Write-Output 'Subnet layout check passed.'
