<#
.SYNOPSIS
    Static checks for Salesforce Voice / Native Voice routing flow XML.

.DESCRIPTION
    Runs the checks in references/checks.md plus the known traps in references/traps.md
    against one or more *.flow-meta.xml files. Read-only: never changes a file or an org.
    Prints element names only, never prompt text, literal values or record data.
    Flow files are parsed as untrusted input (no DTDs or external entities); only well-formed
    flow API names are ever sent to the org.

    Exit code: 0 = no errors, 1 = at least one ERROR (or WARN with -FailOnWarning), 2 = bad input.

.PARAMETER Path
    Flow files and/or folders. Folders are scanned for *.flow-meta.xml.

.PARAMETER Filter
    Wildcard on the flow file name when Path is a folder, e.g. 'IVR_Line_*'.

.PARAMETER Language
    Expected prompt language prefix (en, es, ...). Default: inferred from the file name
    (English / Spanish / _EN_ / _ES_), otherwise the most common language in the flow.

.PARAMETER TargetOrg
    Optional org alias. When set, referenced subflows are checked for an active version
    with a read-only Tooling API query.

.PARAMETER ClientPrefix
    Multi-client orgs: the client's flow prefix, e.g. 'IVR_ACME_'. Limits a folder scan to that client's
    flows, flags subflow calls into other flows (except -SharedFlows) and record-triggered flows whose
    entry criteria are not scoped to the client (IVR_Client__c or a phone-number match).

.PARAMETER SharedFlows
    With -ClientPrefix: client-neutral flows any client may call.

.PARAMETER Json
    Print findings as JSON instead of a table.

.PARAMETER FailOnWarning
    Exit 1 when there are warnings and no errors.

.PARAMETER ShowInfo
    Also show INFO findings (style notes that are often intentional).

.EXAMPLE
    .\Test-IvrFlow.ps1 -Path force-app\main\default\flows -Filter 'IVR_Line_*'

.EXAMPLE
    .\Test-IvrFlow.ps1 -Path .\flows\IVR_Line_Main_Menu.flow-meta.xml -TargetOrg myOrg -Json

.EXAMPLE
    .\Test-IvrFlow.ps1 -Path force-app\main\default\flows -ClientPrefix 'IVR_ACME_' -SharedFlows 'IVR_Post_Call_Summary'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$Filter = '*',
    [string]$Language,
    [string]$TargetOrg,
    [string]$ClientPrefix,
    [string[]]$SharedFlows = @(),
    [switch]$Json,
    [switch]$FailOnWarning,
    [switch]$ShowInfo
)

$ErrorActionPreference = 'Stop'

# Element types that carry a <name> and can be the target of a connector.
$elementTypes = @('actionCalls', 'apexPluginCalls', 'assignments', 'collectionProcessors', 'customErrors',
    'decisions', 'loops', 'orchestratedStages', 'recordCreates', 'recordDeletes', 'recordLookups',
    'recordRollbacks', 'recordUpdates', 'screens', 'steps', 'subflows', 'transforms', 'waits')
$faultActionTypes = @('apex', 'routeWork', 'externalTransferAsyncAction')
$faultRecordTypes = @('recordCreates', 'recordDeletes', 'recordLookups', 'recordUpdates')
$allKeys = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#')
# Minimum API version per voice action (traps.md #3).
$minApi = @{ playPromptAsyncAction = 65; disableRecAndTranscription = 66; externalTransferAsyncAction = 67 }

$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding([string]$flow, [string]$severity, [string]$check, [string]$element, [string]$message) {
    $findings.Add([pscustomobject]@{
            Flow = $flow; Severity = $severity; Check = $check; Element = $element; Message = $message
        })
}

function Get-Param($node, [string]$paramName) {
    # Returns the value text of an actionCalls inputParameter, or $null when unset.
    foreach ($p in @($node.SelectNodes("*[local-name()='inputParameters']"))) {
        if ($p.SelectSingleNode("*[local-name()='name']").InnerText -eq $paramName) {
            $v = $p.SelectSingleNode("*[local-name()='value']")
            if ($null -eq $v -or $null -eq $v.FirstChild) { return $null }
            return [pscustomobject]@{ Kind = $v.FirstChild.LocalName; Text = $v.FirstChild.InnerText }
        }
    }
    return $null
}

function Read-FlowXml([string]$filePath) {
    # Flow files are untrusted input: no DTDs, no external entities, no network access while parsing.
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 50MB
    $reader = [System.Xml.XmlReader]::Create($filePath, $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return $doc
    }
    finally { $reader.Dispose() }
}

function Get-Child($node, [string]$childName) {
    $c = $node.SelectSingleNode("*[local-name()='$childName']")
    if ($c) { return $c.InnerText }
    return $null
}

function Get-LanguageHint([string]$text) {
    if ($text -match '(?i)spanish|espanol|_es(_|$)') { return 'es' }
    if ($text -match '(?i)english|_en(_|$)') { return 'en' }
    return $null
}

function Get-Targets($node) {
    return @($node.SelectNodes(".//*[local-name()='targetReference']") | ForEach-Object { $_.InnerText })
}

# ---- collect files ----
if ($ClientPrefix -and $Filter -eq '*') { $Filter = "$ClientPrefix*" }
$files = @()
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "Path not found: $p"; exit 2 }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        $files += Get-ChildItem -LiteralPath $item.FullName -Filter '*.flow-meta.xml' |
            Where-Object { $_.Name -like "$Filter.flow-meta.xml" -or $_.Name -like $Filter }
    }
    else { $files += $item }
}
if ($files.Count -eq 0) { Write-Error 'No *.flow-meta.xml files matched.'; exit 2 }

$subflowRefs = @{}   # subflow name -> list of "flow/element" that call it

foreach ($file in $files) {
    $flowName = $file.Name -replace '\.flow-meta\.xml$', ''
    try { $doc = Read-FlowXml $file.FullName }
    catch { Add-Finding $flowName 'ERROR' 'parse' '' "Not valid XML: $($_.Exception.Message)"; continue }
    $flow = $doc.DocumentElement
    $apiVersion = [double](Get-Child $flow 'apiVersion')
    $processType = Get-Child $flow 'processType'

    # ---- index elements ----
    $elements = @{}
    foreach ($t in $elementTypes) {
        foreach ($n in @($flow.SelectNodes("*[local-name()='$t']"))) {
            $elements[(Get-Child $n 'name')] = [pscustomobject]@{ Type = $t; Node = $n }
        }
    }
    $prompts = @{}
    foreach ($name in $elements.Keys) {
        $e = $elements[$name]
        if ($e.Type -eq 'actionCalls' -and (Get-Child $e.Node 'actionType') -eq 'playPromptAsyncAction') { $prompts[$name] = $e.Node }
    }

    # ---- 1. every connector target exists ----
    $startNode = $flow.SelectSingleNode("*[local-name()='start']")
    $sources = @()
    if ($startNode) { $sources += , @('start', $startNode) }
    foreach ($name in $elements.Keys) { $sources += , @($name, $elements[$name].Node) }
    foreach ($s in $sources) {
        foreach ($target in Get-Targets $s[1]) {
            if (-not $elements.ContainsKey($target)) {
                Add-Finding $flowName 'ERROR' 'connector-target' $s[0] "Connector points to missing element '$target'."
            }
        }
    }

    # ---- 2. every element reachable from start ----
    if (-not $startNode) {
        Add-Finding $flowName 'ERROR' 'reachable' 'start' 'Flow has no start element.'
    }
    else {
        $seen = @{}
        $queue = New-Object System.Collections.Generic.Queue[string]
        foreach ($t in Get-Targets $startNode) { $queue.Enqueue($t) }
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($seen.ContainsKey($cur) -or -not $elements.ContainsKey($cur)) { continue }
            $seen[$cur] = $true
            foreach ($t in Get-Targets $elements[$cur].Node) { $queue.Enqueue($t) }
        }
        foreach ($name in $elements.Keys) {
            if (-not $seen.ContainsKey($name)) {
                Add-Finding $flowName 'WARN' 'reachable' $name 'Element is not reachable from start.'
            }
        }
    }

    # ---- 3 + 4 + prompt conventions ----
    $langCounts = @{}
    foreach ($name in $prompts.Keys) {
        $lv = Get-Param $prompts[$name] 'languageValue'
        if ($lv) { $pre = ($lv.Text -split '-')[0].ToLower(); $langCounts[$pre] = 1 + [int]$langCounts[$pre] }
    }
    # Language: -Language wins, then the prompt's own name (Ask_X_EN, Ask_Language_Spanish), then the flow's
    # name. A flow mixing languages with no name hint (e.g. a shared entry or queue flow) is not checked.
    $flowLang = $Language
    if (-not $flowLang) { $flowLang = Get-LanguageHint $flowName }
    if (-not $flowLang -and $langCounts.Count -eq 1) { $flowLang = @($langCounts.Keys)[0] }

    $noVoice = @()
    $partialKeys = @()
    foreach ($name in $prompts.Keys) {
        $node = $prompts[$name]
        $promptType = Get-Param $node 'promptType'
        $msg = Get-Param $node 'promptMessage'
        $media = Get-Param $node 'mediaName'
        $collects = (Get-Param $node 'userResponseSettings').Text -eq 'true'
        $responseValues = Get-Param $node 'responseValues'

        # 3. prompt text
        if (($null -eq $promptType -or $promptType.Text -eq 'Message') -and
            ($null -eq $msg -or [string]::IsNullOrWhiteSpace($msg.Text)) -and $null -eq $media) {
            Add-Finding $flowName 'ERROR' 'prompt-text' $name 'Prompt has no message text and no media.'
        }

        # 4. language
        $lv = Get-Param $node 'languageValue'
        if ($null -eq $lv) {
            Add-Finding $flowName 'ERROR' 'prompt-language' $name 'languageValue is not set.'
        }
        else {
            $expectedLang = $null
            if (-not $Language) { $expectedLang = Get-LanguageHint $name }
            if (-not $expectedLang) { $expectedLang = $flowLang }
            if ($expectedLang -and (($lv.Text -split '-')[0].ToLower() -ne $expectedLang)) {
                Add-Finding $flowName 'ERROR' 'prompt-language' $name "languageValue '$($lv.Text)' but this prompt should be '$expectedLang'."
            }
        }
        if ($null -eq (Get-Param $node 'voiceProfileValue')) { $noVoice += $name }

        # SSML: only <break> and <phoneme> are supported (conventions.md).
        if ($msg -and $msg.Text -match '<\s*(?!/?\s*(break|phoneme|speak)\b)/?\s*([a-zA-Z:-]+)') {
            Add-Finding $flowName 'ERROR' 'prompt-ssml' $name "Unsupported SSML tag <$($Matches[2])>; only <break> and <phoneme> work."
        }

        if ($collects) {
            # traps.md #1
            if ((Get-Param $node 'requireResponseRetry').Text -eq 'true') {
                Add-Finding $flowName 'ERROR' 'prompt-retry' $name 'requireResponseRetry=true: input counts only on the 3rd entry. Set false and retry in the flow.'
            }
            # traps.md #2
            if ($null -eq $responseValues -or [string]::IsNullOrWhiteSpace($responseValues.Text)) {
                Add-Finding $flowName 'ERROR' 'prompt-keys' $name "Collects input but responseValues is empty (deploy error). Use '*' for free-digit entry."
            }
            elseif ($responseValues.Text.Trim() -ne '*') {
                $accepted = $responseValues.Text -split ',' | ForEach-Object { $_.Trim() }
                $missing = $allKeys | Where-Object { $accepted -notcontains $_ }
                if ($missing) { $partialKeys += $name }
            }
        }
    }
    if ($noVoice.Count -gt 0) {
        Add-Finding $flowName 'WARN' 'prompt-voice' ($noVoice -join ', ') "$($noVoice.Count) prompt(s) have no voiceProfileValue (there is no global voice setting); callers may hear a different voice."
    }
    if ($partialKeys.Count -gt 0) {
        Add-Finding $flowName 'INFO' 'prompt-keys' ($partialKeys -join ', ') 'Prompt(s) accept only some keys; a wrong key then behaves like no input. Fine for single-key offers, not for menus.'
    }

    # ---- 5. fault paths ----
    foreach ($name in $elements.Keys) {
        $e = $elements[$name]
        $hasFault = $null -ne $e.Node.SelectSingleNode("*[local-name()='faultConnector']")
        if ($e.Type -eq 'actionCalls') {
            $at = Get-Child $e.Node 'actionType'
            if ($faultActionTypes -contains $at -and -not $hasFault) {
                Add-Finding $flowName 'ERROR' 'fault-path' $name "$at action has no fault connector."
            }
            if ($minApi.ContainsKey($at) -and $apiVersion -lt $minApi[$at]) {
                Add-Finding $flowName 'ERROR' 'api-version' $name "$at needs API $($minApi[$at])+; flow is $apiVersion. Deploy with package.xml 68.0."
            }
            # traps.md #4
            if ($at -eq 'routeWork') {
                $q = Get-Param $e.Node 'queueId'
                if ($q -and $q.Kind -eq 'elementReference') {
                    Add-Finding $flowName 'WARN' 'route-queue' $name 'Queue passed in a variable; agents may not ring. Select a fixed queue.'
                }
            }
        }
        elseif ($faultRecordTypes -contains $e.Type -and -not $hasFault) {
            Add-Finding $flowName 'ERROR' 'fault-path' $name "$($e.Type) has no fault connector; a failure drops the call."
        }
    }

    # ---- 6. decisions test only keys the prompt accepts ----
    $keyVars = @{}   # variable -> prompts whose dtmfInput is assigned to it
    foreach ($name in $elements.Keys) {
        if ($elements[$name].Type -ne 'assignments') { continue }
        foreach ($item in @($elements[$name].Node.SelectNodes("*[local-name()='assignmentItems']"))) {
            $ref = $item.SelectSingleNode("*[local-name()='value']/*[local-name()='elementReference']")
            if ($ref -and $ref.InnerText -match '^(\w+)\.dtmfInput$') {
                $var = Get-Child $item 'assignToReference'
                if (-not $keyVars.ContainsKey($var)) { $keyVars[$var] = @() }
                $keyVars[$var] += $Matches[1]
            }
        }
    }
    foreach ($name in $elements.Keys) {
        if ($elements[$name].Type -ne 'decisions') { continue }
        foreach ($cond in @($elements[$name].Node.SelectNodes(".//*[local-name()='conditions']"))) {
            $left = Get-Child $cond 'leftValueReference'
            $right = $cond.SelectSingleNode("*[local-name()='rightValue']/*[local-name()='stringValue']")
            if ($null -eq $right -or (Get-Child $cond 'operator') -ne 'EqualTo') { continue }
            $sourcePrompts = @()
            if ($left -match '^(\w+)\.dtmfInput$') { $sourcePrompts = @($Matches[1]) }
            elseif ($keyVars.ContainsKey($left)) { $sourcePrompts = $keyVars[$left] }
            foreach ($sp in $sourcePrompts | Select-Object -Unique) {
                if (-not $prompts.ContainsKey($sp)) { continue }
                $rv = Get-Param $prompts[$sp] 'responseValues'
                if ($null -eq $rv -or $rv.Text.Trim() -eq '*') { continue }
                $accepted = $rv.Text -split ',' | ForEach-Object { $_.Trim() }
                if ($accepted -notcontains $right.InnerText) {
                    Add-Finding $flowName 'ERROR' 'decision-key' $name "Tests key '$($right.InnerText)' but prompt '$sp' only accepts '$($rv.Text)'; this branch can never run."
                }
            }
        }
    }

    # ---- 7. dead ends ----
    # An element without a connector ends the flow, which is how subflows return (e.g. Set nextStep).
    # Flagged only where ending is almost certainly a mistake.
    foreach ($name in $elements.Keys) {
        $e = $elements[$name]
        $hasNext = $null -ne $e.Node.SelectSingleNode("*[local-name()='connector']")
        if ($prompts.ContainsKey($name) -and -not $hasNext -and (Get-Param $e.Node 'userResponseSettings').Text -eq 'true') {
            Add-Finding $flowName 'ERROR' 'dead-end' $name 'Prompt collects a key but has no next element; the input is ignored and the flow ends.'
        }
    }

    # ---- 8. subflows exist (locally; in the org with -TargetOrg) ----
    foreach ($name in $elements.Keys) {
        if ($elements[$name].Type -ne 'subflows') { continue }
        $target = Get-Child $elements[$name].Node 'flowName'
        if (-not $subflowRefs.ContainsKey($target)) { $subflowRefs[$target] = @() }
        $subflowRefs[$target] += "$flowName/$name"
        if ($ClientPrefix -and -not $target.StartsWith($ClientPrefix, [StringComparison]::OrdinalIgnoreCase) -and $SharedFlows -notcontains $target) {
            Add-Finding $flowName 'ERROR' 'client-isolation' $name "Calls '$target', which is not a '$ClientPrefix' flow or a listed shared flow; another client's change would reach these callers."
        }
        $local = Join-Path $file.DirectoryName "$target.flow-meta.xml"
        if (-not (Test-Path -LiteralPath $local)) {
            Add-Finding $flowName 'WARN' 'subflow' $name "Subflow '$target' not found next to this flow; check it exists in the org."
        }
        else {
            $sub = Read-FlowXml $local
            $status = Get-Child $sub.DocumentElement 'status'
            if ($status -and $status -ne 'Active') {
                Add-Finding $flowName 'WARN' 'subflow' $name "Local copy of subflow '$target' has status '$status'."
            }
        }
    }

    # Multi-client: a record-triggered flow must only fire for this client's calls/records.
    $triggerType = if ($startNode) { Get-Child $startNode 'triggerType' } else { $null }
    if ($ClientPrefix -and $triggerType -like 'Record*') {
        $scoped = $false
        foreach ($flt in @($startNode.SelectNodes("*[local-name()='filters']"))) {
            $field = Get-Child $flt 'field'
            $op = Get-Child $flt 'operator'
            $hasValue = $null -ne $flt.SelectSingleNode("*[local-name()='value']/*[local-name()='stringValue' or local-name()='elementReference']")
            if ($hasValue -and ($field -eq 'IVR_Client__c' -or ($field -like '*PhoneNumber' -and $op -in 'EqualTo', 'StartsWith'))) { $scoped = $true }
        }
        $formula = Get-Child $startNode 'filterFormula'
        if ($formula -and $formula -match 'IVR_Client__c|PhoneNumber') { $scoped = $true }
        if (-not $scoped) {
            $obj = Get-Child $startNode 'object'
            Add-Finding $flowName 'WARN' 'client-scope' 'start' "Record-triggered on $obj without a client filter (IVR_Client__c or the client's phone numbers); it runs for every client's records."
        }
    }

    # Hard-coded secrets or back-end identifiers: report where, never the value (security.md §3).
    $secretHits = @{}
    foreach ($sv in @($flow.SelectNodes(".//*[local-name()='stringValue']"))) {
        $text = $sv.InnerText.Trim()
        $holder = $sv.ParentNode.ParentNode
        $paramName = Get-Child $holder 'name'
        if ($paramName -in 'queueId', 'serviceChannelId', 'routingConfigId', 'agentId', 'botId') { continue }
        $owner = $holder
        while ($owner -and $owner.ParentNode -ne $flow) { $owner = $owner.ParentNode }
        $ownerName = if ($owner) { Get-Child $owner 'name' } else { $null }
        if (-not $ownerName) { $ownerName = if ($owner) { $owner.LocalName } else { '' } }
        $looksSecret = ($paramName -match '(?i)(secret|token|password|passwd|api_?key|apikey|tenant|credential|auth)') -and $text.Length -ge 8
        $looksRandom = $text -notmatch '\s' -and $text.Length -ge 24 -and $text -match '[0-9]' -and $text -match '[A-Za-z]' -and
            $text -notmatch '^\{!' -and $text -notmatch '^[A-Za-z]+(_[A-Za-z0-9]+)+$'
        if ($looksSecret -or $looksRandom) { $secretHits[$ownerName] = $true }
    }
    foreach ($el in $secretHits.Keys) {
        Add-Finding $flowName 'ERROR' 'hardcoded-secret' $el 'Literal value looks like a key, token or back-end code. Move it to a Named Credential or client config and rotate it if it is a secret. (Value not shown.)'
    }

    if ($processType -and $processType -ne 'RoutingFlow' -and $prompts.Count -gt 0) {
        Add-Finding $flowName 'WARN' 'process-type' '' "Flow plays prompts but processType is '$processType', not RoutingFlow."
    }
}

# ---- subflows active in the org (read-only Tooling query) ----
if ($TargetOrg -and $TargetOrg -notmatch '^[A-Za-z0-9_.@-]+$') {
    Write-Error "TargetOrg '$TargetOrg' is not a valid alias or username."; exit 2
}
# Only well-formed API names reach the query (flow files are untrusted input).
$queryable = @($subflowRefs.Keys | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9_]{0,79}$' })
foreach ($bad in @($subflowRefs.Keys | Where-Object { $queryable -notcontains $_ })) {
    Add-Finding '(org)' 'ERROR' 'subflow' '' "A subflow reference is not a valid flow API name (called from $($subflowRefs[$bad] -join ', '))."
    $subflowRefs.Remove($bad)
}
if ($TargetOrg -and $queryable.Count -gt 0) {
    $names = ($queryable | ForEach-Object { "'$_'" }) -join ','
    $soql = "SELECT DeveloperName, ActiveVersionId FROM FlowDefinition WHERE DeveloperName IN ($names)"
    $raw = & sf data query --use-tooling-api -o $TargetOrg -q $soql --json 2>$null
    $result = $null
    try { $result = ($raw -join "`n") | ConvertFrom-Json } catch { }
    if ($null -eq $result -or $result.status -ne 0) {
        Add-Finding '(org)' 'WARN' 'subflow-org' '' "Could not query FlowDefinition in '$TargetOrg'; subflow activation not checked."
    }
    else {
        $active = @{}
        foreach ($r in $result.result.records) { $active[$r.DeveloperName] = [bool]$r.ActiveVersionId }
        foreach ($sf in $subflowRefs.Keys) {
            if (-not $active.ContainsKey($sf)) {
                Add-Finding '(org)' 'ERROR' 'subflow-org' $sf "Subflow does not exist in '$TargetOrg' (called from $($subflowRefs[$sf] -join ', '))."
            }
            elseif (-not $active[$sf]) {
                Add-Finding '(org)' 'ERROR' 'subflow-org' $sf "Subflow has no active version in '$TargetOrg' (called from $($subflowRefs[$sf] -join ', '))."
            }
        }
    }
}

# ---- report ----
$errors = @($findings | Where-Object Severity -eq 'ERROR').Count
$warnings = @($findings | Where-Object Severity -eq 'WARN').Count
if (-not $ShowInfo) { $findings = @($findings | Where-Object Severity -ne 'INFO') }
$rank = @{ ERROR = 0; WARN = 1; INFO = 2 }

if ($Json) {
    [pscustomobject]@{
        flowsChecked = $files.Count; errors = $errors; warnings = $warnings
        findings     = @($findings)
    } | ConvertTo-Json -Depth 4
}
else {
    $currentFlow = $null
    foreach ($f in $findings | Sort-Object Flow, @{ Expression = { $rank[$_.Severity] } }, Check, Element) {
        if ($f.Flow -ne $currentFlow) { Write-Output ''; Write-Output "== $($f.Flow)"; $currentFlow = $f.Flow }
        $where = if ($f.Element) { " [$($f.Element)]" } else { '' }
        Write-Output ('  {0,-5} {1,-16}{2} {3}' -f $f.Severity, $f.Check, $where, $f.Message)
    }
    Write-Output ''
    foreach ($file in $files) {
        $fn = $file.Name -replace '\.flow-meta\.xml$', ''
        $e = @($findings | Where-Object { $_.Flow -eq $fn -and $_.Severity -eq 'ERROR' }).Count
        $w = @($findings | Where-Object { $_.Flow -eq $fn -and $_.Severity -eq 'WARN' }).Count
        $mark = if ($e -gt 0) { 'FAIL' } else { 'PASS' }
        Write-Output ('{0}  {1}  ({2} errors, {3} warnings)' -f $mark, $fn, $e, $w)
    }
    Write-Output ''
    Write-Output ("Checked {0} flow(s): {1} error(s), {2} warning(s)." -f $files.Count, $errors, $warnings)
}

if ($errors -gt 0 -or ($FailOnWarning -and $warnings -gt 0)) { exit 1 }
exit 0
