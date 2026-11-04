<#
.SYNOPSIS
    Safe deploy for Salesforce Voice IVR flows (and optional Apex): draft check, backup, API 68.0 package,
    dry run, deploy, verify that the new version is active, rollback hint and deploy log.

.DESCRIPTION
    Default is a DRY RUN (check-only; nothing in the org changes). Add -Deploy to deploy for real; the dry
    run always runs first and must pass.

    Stops before deploying when:
      - a name is not a valid API name;
      - a flow's latest version is not its active version (someone has a draft; deploying would overwrite it);
      - the org is production and -AllowProduction was not given;
      - the local file is missing;
      - the dry run fails.

    Prints the org host, sandbox flag, flow versions, deploy Ids and component / test errors only.
    Never queries or prints record data.

.EXAMPLE
    # Dry run only
    .\Deploy-IvrFlow.ps1 -TargetOrg my-sandbox -FlowName IVR_ACME_Agent_Handoff

.EXAMPLE
    # Real deploy of two flows plus an Apex class with its test, with a deploy log
    .\Deploy-IvrFlow.ps1 -TargetOrg my-sandbox -FlowName IVR_ACME_Entry,IVR_ACME_EN_Menu `
        -ApexClass HoursCheckService -TestClass HoursCheckServiceTest -LogFile .\docs\deploy-log.md -Deploy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetOrg,
    [Parameter(Mandatory = $true)][string[]]$FlowName,
    [string]$SourceDir = 'force-app\main\default\flows',
    [string[]]$ApexClass = @(),
    [string]$ApexDir = 'force-app\main\default\classes',
    [string[]]$TestClass = @(),
    [string]$ApiVersion = '68.0',
    [string]$BackupRoot = '.\ivr-deploy-backups',
    [string]$LogFile,
    [int]$WaitMinutes = 30,
    [switch]$Deploy,
    [switch]$AllowProduction
)

$ErrorActionPreference = 'Stop'
$apiName = '^[A-Za-z][A-Za-z0-9_]{0,79}$'

function Invoke-Sf {
    param([string[]]$SfArgs)
    # Windows PowerShell 5.1 turns any native stderr line (e.g. "update available") into an error under Stop.
    $env:SF_SKIP_NEW_VERSION_CHECK = 'true'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = (& sf @SfArgs --json 2>$null) | Out-String } finally { $ErrorActionPreference = $prev }
    if (-not $raw.Trim()) { throw "sf returned no output for: sf $($SfArgs[0..1] -join ' ')" }
    try { return $raw | ConvertFrom-Json } catch { throw "sf output was not JSON for: sf $($SfArgs[0..1] -join ' ')" }
}

function Get-FlowVersions {
    param([string[]]$Names)
    $in = ($Names | ForEach-Object { "'$_'" }) -join ','
    $q = "SELECT Id, DeveloperName, ActiveVersion.VersionNumber, LatestVersion.VersionNumber FROM FlowDefinition WHERE DeveloperName IN ($in)"
    $res = Invoke-Sf @('data', 'query', '--use-tooling-api', '-o', $TargetOrg, '-q', $q)
    if ($res.status -ne 0) { throw "FlowDefinition query failed: $($res.message)" }
    $map = @{}
    foreach ($r in @($res.result.records)) {
        if (-not $r) { continue }
        $active = $null; $latest = $null
        if ($r.ActiveVersion) { $active = [int]$r.ActiveVersion.VersionNumber }
        if ($r.LatestVersion) { $latest = [int]$r.LatestVersion.VersionNumber }
        $map[$r.DeveloperName] = [pscustomobject]@{ Id = $r.Id; Active = $active; Latest = $latest }
    }
    return $map
}

function Write-Failures {
    param($Result)
    $d = $null
    if ($Result.result) { $d = $Result.result.details }
    if ($d) {
        foreach ($f in @($d.componentFailures)) { if ($f) { Write-Host "  component  $($f.componentType) $($f.fullName): $($f.problem)" -ForegroundColor Red } }
        $rt = $d.runTestResult
        if ($rt) { foreach ($t in @($rt.failures)) { if ($t) { Write-Host "  test       $($t.name).$($t.methodName): $($t.message)" -ForegroundColor Red } } }
    }
    if ($Result.message) { Write-Host "  message    $($Result.message)" -ForegroundColor Red }
}

function Add-Log {
    param([string]$Line)
    if (-not $LogFile) { return }
    if (-not (Test-Path -LiteralPath $LogFile)) {
        $header = "| Date | Org | Sandbox | Components | Dry run | Deploy | Result |`r`n|---|---|---|---|---|---|---|`r`n"
        [IO.File]::WriteAllText($LogFile, $header, (New-Object Text.UTF8Encoding($false)))
    }
    [IO.File]::AppendAllText($LogFile, $Line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

# ---------- 1. inputs ----------
foreach ($n in @($FlowName) + @($ApexClass) + @($TestClass)) {
    if ($n -notmatch $apiName) { throw "Not a valid API name: '$n'" }
}
foreach ($n in $FlowName) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir "$n.flow-meta.xml"))) { throw "Missing local file: $SourceDir\$n.flow-meta.xml" }
}
foreach ($n in $ApexClass) {
    foreach ($ext in '.cls', '.cls-meta.xml') {
        if (-not (Test-Path -LiteralPath (Join-Path $ApexDir "$n$ext"))) { throw "Missing local file: $ApexDir\$n$ext" }
    }
}

# ---------- 2. which org ----------
$org = Invoke-Sf @('org', 'display', '-o', $TargetOrg)
if ($org.status -ne 0) { throw "Cannot reach org '$TargetOrg': $($org.message)" }
$orgHost = ([uri]$org.result.instanceUrl).Host
$sb = Invoke-Sf @('data', 'query', '-o', $TargetOrg, '-q', 'SELECT IsSandbox FROM Organization')
$isSandbox = [bool]$sb.result.records[0].IsSandbox
Write-Host "Org: $orgHost  sandbox: $(if ($isSandbox) { 'yes' } else { 'NO (production)' })" -ForegroundColor Cyan
if (-not $isSandbox -and $Deploy -and -not $AllowProduction) {
    throw 'Production org: a real deploy needs -AllowProduction AND the owner''s explicit approval naming this org.'
}

# ---------- 3. draft check ----------
$before = Get-FlowVersions $FlowName
$blocked = $false
foreach ($n in $FlowName) {
    $v = $before[$n]
    if (-not $v) { Write-Host "  $n  new flow (no versions in the org)"; continue }
    if ($null -eq $v.Active) {
        Write-Host "  $n  no active version; latest v$($v.Latest) may be someone's draft. Stop and ask." -ForegroundColor Yellow
        $blocked = $true
    } elseif ($v.Latest -ne $v.Active) {
        Write-Host "  $n  active v$($v.Active) but latest v$($v.Latest): a newer draft exists. Retrieve it and ask before deploying." -ForegroundColor Yellow
        $blocked = $true
    } else {
        Write-Host "  $n  active v$($v.Active) = latest"
    }
}
if ($blocked) { throw 'Stopped: draft or inactive latest version found (see above). Nothing was deployed.' }

# ---------- 4. package (API version pinned) ----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$pkg = Join-Path ([IO.Path]::GetTempPath()) "ivr-pkg-$stamp"
New-Item -ItemType Directory -Force (Join-Path $pkg 'flows') | Out-Null
foreach ($n in $FlowName) { Copy-Item -LiteralPath (Join-Path $SourceDir "$n.flow-meta.xml") -Destination (Join-Path $pkg "flows\$n.flow") }
$types = "  <types>`r`n" + (($FlowName | ForEach-Object { "    <members>$_</members>" }) -join "`r`n") + "`r`n    <name>Flow</name>`r`n  </types>`r`n"
if ($ApexClass.Count) {
    New-Item -ItemType Directory -Force (Join-Path $pkg 'classes') | Out-Null
    foreach ($n in $ApexClass) {
        Copy-Item -LiteralPath (Join-Path $ApexDir "$n.cls") -Destination (Join-Path $pkg "classes\$n.cls")
        Copy-Item -LiteralPath (Join-Path $ApexDir "$n.cls-meta.xml") -Destination (Join-Path $pkg "classes\$n.cls-meta.xml")
    }
    $types += "  <types>`r`n" + (($ApexClass | ForEach-Object { "    <members>$_</members>" }) -join "`r`n") + "`r`n    <name>ApexClass</name>`r`n  </types>`r`n"
}
$xml = "<?xml version=""1.0"" encoding=""UTF-8""?>`r`n<Package xmlns=""http://soap.sforce.com/2006/04/metadata"">`r`n$types  <version>$ApiVersion</version>`r`n</Package>`r`n"
[IO.File]::WriteAllText((Join-Path $pkg 'package.xml'), $xml, (New-Object Text.UTF8Encoding($false)))
Write-Host "Package: $pkg (API $ApiVersion)"

$deployArgs = @('project', 'deploy', 'start', '-o', $TargetOrg, '--metadata-dir', $pkg, '--wait', [string]$WaitMinutes)
if ($TestClass.Count) {
    $deployArgs += @('--test-level', 'RunSpecifiedTests')
    foreach ($t in $TestClass) { $deployArgs += @('--tests', $t) }
} elseif ($ApexClass.Count -and -not $isSandbox) {
    throw 'Production deploys with Apex need -TestClass.'
}

# ---------- 5. dry run ----------
Write-Host 'Dry run (check-only)...' -ForegroundColor Cyan
$dry = Invoke-Sf ($deployArgs + @('--dry-run'))
$dryId = $null; if ($dry.result) { $dryId = $dry.result.id }
if ($dry.status -ne 0 -or -not $dry.result.success) {
    Write-Host "Dry run FAILED ($dryId)" -ForegroundColor Red
    Write-Failures $dry
    Add-Log "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $orgHost | $isSandbox | $(($FlowName + $ApexClass) -join ', ') | $dryId failed | - | stopped |"
    exit 1
}
Write-Host "Dry run passed ($dryId)" -ForegroundColor Green
if (-not $Deploy) {
    Write-Host 'Nothing deployed (no -Deploy). Get approval, then rerun with -Deploy.'
    Add-Log "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $orgHost | $isSandbox | $(($FlowName + $ApexClass) -join ', ') | $dryId passed | - | dry run only |"
    return
}

# ---------- 6. backup current org versions ----------
$backup = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force $backup | Out-Null
$retrieveArgs = @('project', 'retrieve', 'start', '-o', $TargetOrg, '--target-metadata-dir', $backup, '--unzip')
foreach ($n in $FlowName) { if ($before[$n]) { $retrieveArgs += @('-m', "Flow:$n") } }
if ($ApexClass.Count) { foreach ($n in $ApexClass) { $retrieveArgs += @('-m', "ApexClass:$n") } }
if ($retrieveArgs -contains '-m') {
    $bk = Invoke-Sf $retrieveArgs
    if ($bk.status -ne 0) { throw "Backup retrieve failed: $($bk.message). Nothing was deployed." }
    Write-Host "Backup: $backup"
}

# ---------- 7. deploy ----------
Write-Host 'Deploying...' -ForegroundColor Cyan
$dep = Invoke-Sf $deployArgs
$depId = $null; if ($dep.result) { $depId = $dep.result.id }
if ($dep.status -ne 0 -or -not $dep.result.success) {
    Write-Host "Deploy FAILED ($depId)" -ForegroundColor Red
    Write-Failures $dep
    Add-Log "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $orgHost | $isSandbox | $(($FlowName + $ApexClass) -join ', ') | $dryId passed | $depId failed | failed |"
    exit 1
}

# ---------- 8. verify ----------
$after = Get-FlowVersions $FlowName
$ok = $true
$summary = @()
foreach ($n in $FlowName) {
    $a = $after[$n]; $b = $before[$n]
    $old = 'new'; if ($b -and $b.Active) { $old = "v$($b.Active)" }
    if (-not $a -or $null -eq $a.Active -or $a.Active -ne $a.Latest) {
        Write-Host "  $n  NOT active after deploy (active: $(if ($a) { $a.Active } else { 'none' }), latest: $(if ($a) { $a.Latest } else { 'none' }))" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "  $n  $old -> v$($a.Active) active" -ForegroundColor Green
    }
    if ($a) { $summary += "$n $old->v$($a.Latest)" }
    if ($b -and $b.Active) {
        Write-Host "     rollback: PATCH /services/data/v$ApiVersion/tooling/sobjects/FlowDefinition/$($b.Id)  body {""Metadata"":{""activeVersionNumber"":$($b.Active)}}  (or redeploy $backup)"
    }
}
Add-Log "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $orgHost | $isSandbox | $(($summary + $ApexClass) -join ', ') | $dryId passed | $depId | $(if ($ok) { 'deployed, active = latest' } else { 'deployed, NOT active - check' }) |"
if (-not $ok) { exit 1 }
Write-Host "Done ($depId). Retrieve to sync source: sf project retrieve start -o $TargetOrg $(($FlowName | ForEach-Object { "-m Flow:$_" }) -join ' ') --ignore-conflicts"
