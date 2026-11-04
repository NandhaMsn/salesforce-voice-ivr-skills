<#
.SYNOPSIS
    Inventories Amazon Connect contact-flow exports and maps every block to its Salesforce Voice element.

.DESCRIPTION
    Read-only. Reads exported contact-flow JSON (flow language with an "Actions" array, or the
    DescribeContactFlow wrapper with ContactFlow.Content) and writes a Markdown report:
    flows, prompts, keypad menus and digit entry, Lambda calls, attributes, transfers, queues,
    hours checks, the Salesforce element each block becomes, gaps to decide with the business,
    and data-safety findings.

    Exports are untrusted data. Phone numbers, emails, AWS account Ids and key-like strings are
    masked in everything printed, and contact-attribute VALUES are never printed (names only).

.EXAMPLE
    .\Get-ConnectInventory.ps1 -Path .\connect-exports -OutFile .\connect-inventory.md -Mermaid

.EXAMPLE
    .\Get-ConnectInventory.ps1 -Path .\connect-exports -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$OutFile,
    [switch]$Mermaid,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:masked = @{ phone = 0; email = 0; awsAccount = 0; keyLike = 0 }
$allowedSsml = @('speak', 'break', 'phoneme')

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Protect-Text {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = [regex]::Replace($Text, '[\w.+-]+@[\w-]+(\.[\w-]+)+',
        [System.Text.RegularExpressions.MatchEvaluator] { param($m) $script:masked.email++; '<email>' })
    $t = [regex]::Replace($t, '(arn:aws[\w-]*:[\w-]+:[\w-]*:)\d{12}',
        [System.Text.RegularExpressions.MatchEvaluator] { param($m) $script:masked.awsAccount++; $m.Groups[1].Value + '<account>' })
    $t = [regex]::Replace($t, '(?<![\w-])\+?\d{10,15}(?![\w-])|(?<![\w-])(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\w-])',
        [System.Text.RegularExpressions.MatchEvaluator] { param($m) $script:masked.phone++; '<phone>' })
    $t = [regex]::Replace($t, '(?<![\w-])(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{32,}(?![\w-])',
        [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            if ($m.Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $m.Value }
            $script:masked.keyLike++; '<redacted>'
        })
    return $t
}

function Format-Cell {
    param([string]$Text, [int]$Max = 110)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim() -replace '\|', '\|'
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1) + '...' }
    return $t
}

function Get-MetaText {
    param($ActionMeta)
    foreach ($k in 'ContactFlow', 'contactFlow', 'queue', 'Queue', 'Hours', 'hoursOfOperation', 'flowModule') {
        $v = Get-Prop $ActionMeta $k
        if ($v) {
            foreach ($n in 'text', 'displayName', 'name') { $s = Get-Prop $v $n; if ($s) { return [string]$s } }
        }
    }
    return $null
}

function Get-Tail {
    param([string]$Arn)
    if ([string]::IsNullOrEmpty($Arn)) { return '' }
    if ($Arn -match 'function:([^:]+)') { return $Matches[1] }
    return ($Arn -split '[/:]')[-1]
}

function Get-PromptInfo {
    param($Params)
    $text = [string](Get-Prop $Params 'Text')
    if (-not $text) { $text = [string](Get-Prop $Params 'SSML') }
    if (-not $text) {
        if ((Get-Prop $Params 'PromptId') -or (Get-Prop $Params 'Media')) {
            return @{ Text = '(recorded audio prompt)'; Audio = $true; Unsupported = @() }
        }
        return @{ Text = ''; Audio = $false; Unsupported = @() }
    }
    $unsupported = @()
    foreach ($tag in [regex]::Matches($text, '<\s*([a-zA-Z][\w:\-]*)')) {
        $n = $tag.Groups[1].Value.ToLower()
        if ($allowedSsml -notcontains $n -and $unsupported -notcontains $n) { $unsupported += $n }
    }
    return @{ Text = (Protect-Text $text); Audio = $false; Unsupported = $unsupported }
}

function Find-Secrets {
    # Names only: returns attribute names whose literal value looks like a credential. Values are never returned.
    param($Bag)
    $hits = @()
    if ($null -eq $Bag) { return $hits }
    foreach ($prop in $Bag.PSObject.Properties) {
        $v = [string]$prop.Value
        if ([string]::IsNullOrEmpty($v) -or $v.StartsWith('$.')) { continue }
        $nameLooks = $prop.Name -match '(?i)(secret|token|password|passwd|api_?key|apikey|credential|auth|client_?id)'
        $valueLooks = ($v.Length -ge 24) -and ($v -match '^[A-Za-z0-9_\-+/=.]+$') -and ($v -match '\d') -and ($v -match '[A-Za-z]')
        if (($nameLooks -and $v.Length -ge 8) -or $valueLooks) { $hits += $prop.Name }
    }
    return $hits
}

function Get-Mapping {
    param($Action, $ActionMeta)
    $type = [string](Get-Prop $Action 'Type')
    $p = Get-Prop $Action 'Parameters'
    $tr = Get-Prop $Action 'Transitions'
    $keys = @()
    foreach ($c in @(Get-Prop $tr 'Conditions')) {
        if ($c) { foreach ($o in @(Get-Prop (Get-Prop $c 'Condition') 'Operands')) { if ($null -ne $o) { $keys += [string]$o } } }
    }
    $errs = @()
    foreach ($e in @(Get-Prop $tr 'Errors')) { if ($e) { $errs += [string](Get-Prop $e 'ErrorType') } }
    $metaName = Get-MetaText $ActionMeta

    $r = [ordered]@{ Type = $type; Element = ''; Detail = ''; Gaps = @(); Category = 'other'; Lambda = $null; Target = $null; Secrets = @() }
    $r.Secrets = @(Find-Secrets (Get-Prop $p 'LambdaInvocationAttributes')) + @(Find-Secrets (Get-Prop $p 'Attributes'))

    switch ($type) {
        'MessageParticipant' {
            $pi = Get-PromptInfo $p
            $r.Category = 'prompt'; $r.Element = 'Play Prompt (message only)'; $r.Detail = $pi.Text
            if ($pi.Audio) { $r.Gaps += 'Recorded audio prompt: write it as text-to-speech (flow media prompts were unreliable).' }
            if ($pi.Unsupported.Count) { $r.Gaps += "Unsupported SSML <$($pi.Unsupported -join '>, <')>: only <break> and <phoneme> work." }
        }
        'GetParticipantInput' {
            $pi = Get-PromptInfo $p
            $r.Category = 'prompt'
            $timeout = [string](Get-Prop $p 'InputTimeLimitSeconds')
            if ([string](Get-Prop $p 'StoreInput') -eq 'True') {
                $max = [string](Get-Prop (Get-Prop (Get-Prop $p 'InputValidation') 'CustomValidation') 'MaximumLength')
                if (-not $max) { $max = '?' }
                $r.Element = "Play Prompt + digit entry (responseValues=*, inputValueLength=$max)"
            } else {
                $k = ($keys | Select-Object -Unique) -join ','
                $r.Element = "Play Prompt + keypad menu (accept all keys; branch on $k)"
            }
            $extra = @()
            if ($timeout) { $extra += "timeout $timeout s" }
            if ($errs.Count) { $extra += "branches: $((($errs | Select-Object -Unique) -join ', ')) -> flow counters, requireResponseRetry=false" }
            $r.Detail = $pi.Text + $(if ($extra.Count) { ' [' + ($extra -join '; ') + ']' } else { '' })
            if ($pi.Audio) { $r.Gaps += 'Recorded audio prompt: write it as text-to-speech.' }
            if ($pi.Unsupported.Count) { $r.Gaps += "Unsupported SSML <$($pi.Unsupported -join '>, <')>: only <break> and <phoneme> work." }
        }
        { $_ -in 'InvokeLambdaFunction', 'ConnectParticipantWithLambda' } {
            $fn = Get-Tail ([string](Get-Prop $p 'LambdaFunctionARN'))
            $inputs = @()
            $attrs = Get-Prop $p 'LambdaInvocationAttributes'
            if ($attrs) { $inputs = @($attrs.PSObject.Properties | ForEach-Object { $_.Name }) }
            $r.Category = 'lambda'; $r.Lambda = @{ Name = (Protect-Text $fn); Inputs = $inputs }
            $r.Element = 'Apex @InvocableMethod (callout=true), returns result code + speech'
            $r.Detail = "Lambda $(Protect-Text $fn)" + $(if ($inputs.Count) { "; inputs: $($inputs -join ', ')" } else { '' })
        }
        'UpdateContactAttributes' {
            $names = @()
            $attrs = Get-Prop $p 'Attributes'
            if ($attrs) { $names = @($attrs.PSObject.Properties | ForEach-Object { $_.Name }) }
            $r.Category = 'data'; $r.Element = 'Update Records on VoiceCall (fault path continues the call)'
            $r.Detail = "attributes: $($names -join ', ') (values not shown)"
        }
        'Compare' {
            $r.Category = 'logic'; $r.Element = 'Decision'
            $r.Detail = "compares $(Protect-Text ([string](Get-Prop $p 'ComparisonValue'))) to $((($keys | Select-Object -Unique) -join ', '))"
        }
        'CheckHoursOfOperation' {
            $r.Category = 'hours'; $r.Element = 'Apex hours check on a Business Hours record (fail open on error)'
            $r.Detail = $(if ($metaName) { "hours: $(Protect-Text $metaName)" } else { 'hours record' })
        }
        'UpdateContactTargetQueue' {
            $r.Category = 'queue'; $r.Element = 'Route Work target: a FIXED queue (not a variable)'
            $r.Detail = $(if ($metaName) { "queue: $(Protect-Text $metaName)" } else { "queue: $(Get-Tail ([string](Get-Prop $p 'QueueId')))" })
        }
        'TransferContactToQueue' {
            $r.Category = 'queue'; $r.Element = 'Route Work, QueueBased, sfdc_phone (transcription on just before)'
        }
        'TransferContactToAgent' {
            $r.Category = 'queue'; $r.Element = 'Route Work to a specific agent'
            $r.Gaps += 'Direct-to-agent transfer: confirm the business still needs it; queue routing is the tested path.'
        }
        'TransferParticipantToThirdParty' {
            $r.Category = 'transfer'; $r.Element = 'externalTransferAsyncAction (Add External Party to Call); fault -> agent handoff'
            $r.Detail = "to $(Protect-Text ([string](Get-Prop $p 'ThirdPartyPhoneNumber')))"
        }
        { $_ -in 'TransferToFlow', 'InvokeFlowModule' } {
            $target = $metaName
            if (-not $target) { $target = Get-Tail ([string](Get-Prop $p 'ContactFlowId')) }
            if (-not $target) { $target = Get-Tail ([string](Get-Prop $p 'FlowModuleId')) }
            $r.Category = 'subflow'; $r.Target = (Protect-Text $target)
            $r.Element = $(if ($type -eq 'InvokeFlowModule') { 'Autolaunched service subflow' } else { 'Routing subflow (returns nextStep)' })
            $r.Detail = "-> $($r.Target)"
        }
        { $_ -in 'UpdateContactRecordingBehavior', 'UpdateContactRecordingAndAnalyticsBehavior' } {
            $r.Category = 'recording'; $r.Element = 'disableRecAndTranscription (can only turn off / back on)'
            $r.Detail = 'IVR-only legs are never recorded on Native Voice; transcription on just before Route Work'
        }
        'UpdateContactTextToSpeechVoice' {
            $r.Category = 'voice'; $r.Element = 'voiceProfileValue + languageValue on EVERY prompt (no global voice)'
        }
        'UpdateContactData' {
            $r.Category = 'voice'; $r.Element = 'Language variable passed to menus; languageValue per prompt'
            $lang = [string](Get-Prop $p 'LanguageCode'); if ($lang) { $r.Detail = "language $lang" }
        }
        'UpdateContactRoutingBehavior' {
            $r.Category = 'queue'; $r.Element = 'Routing configuration priority on the queue'
        }
        'UpdateContactEventHooks' {
            $r.Category = 'queue'; $r.Element = 'None: default queue music'
            $r.Gaps += 'Customer queue / hold flow: in-queue flow actions stopped queue music; offer callbacks before Route Work instead.'
        }
        'UpdateContactCallbackNumber' {
            $r.Category = 'callback'; $r.Element = 'Callback offer: number prompt, read back, confirm (callbacks.md)'
        }
        'CreateCallbackContact' {
            $r.Category = 'callback'; $r.Element = 'Contact Request (IsCallback, IsPreviewCallback) + Route Work to the callback queue'
        }
        { $_ -in 'CheckMetricData', 'GetMetricData' } {
            $r.Category = 'queue'; $r.Element = 'checkAvailabilityForRouting (online agents vs queue size)'
        }
        'DistributeByPercentage' {
            $r.Category = 'logic'; $r.Element = 'Decision on a random formula'
            $r.Gaps += 'Percentage split (A/B test): confirm it is still needed.'
        }
        'Loop' { $r.Category = 'logic'; $r.Element = 'Counter variable + Decision' }
        'Wait' {
            $r.Category = 'logic'; $r.Element = 'None'
            $r.Gaps += 'Wait block: no routing-flow equivalent; use a spoken message or redesign.'
        }
        'UpdateFlowLoggingBehavior' { $r.Category = 'logic'; $r.Element = 'None: debug logs on the integration user (sensitive)' }
        'DisconnectParticipant' { $r.Category = 'end'; $r.Element = 'End the call' }
        'EndFlowExecution' { $r.Category = 'end'; $r.Element = 'Subflow return: assignment that sets nextStep, no connector' }
        default {
            $r.Element = 'UNMAPPED'
            $r.Gaps += "No mapping for block type '$type': review by hand."
        }
    }
    return $r
}

function Get-MermaidLabel {
    param([string]$Text)
    $t = ($Text -replace '[\[\]\{\}\(\)"<>|`#;]', ' ' -replace '\s+', ' ').Trim()
    if ($t.Length -gt 48) { $t = $t.Substring(0, 47) + '...' }
    return $t
}

# ---------- read exports ----------
if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$files = @()
if (Test-Path -LiteralPath $Path -PathType Container) { $files = @(Get-ChildItem -LiteralPath $Path -Filter *.json -File -Recurse) }
else { $files = @(Get-Item -LiteralPath $Path) }

$flows = @()
$skipped = @()
foreach ($f in $files) {
    try { $doc = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json }
    catch { $skipped += "$($f.Name): not valid JSON"; continue }

    $name = $null
    $cf = Get-Prop $doc 'ContactFlow'
    if ($cf) {
        $name = [string](Get-Prop $cf 'Name')
        $content = Get-Prop $cf 'Content'
        if ($content -is [string]) {
            try { $doc = $content | ConvertFrom-Json } catch { $skipped += "$($f.Name): Content is not valid JSON"; continue }
        }
    }
    $actions = @(Get-Prop $doc 'Actions')
    if (-not $actions -or -not $actions[0]) { $skipped += "$($f.Name): no Actions (not a contact flow export)"; continue }

    $meta = Get-Prop $doc 'Metadata'
    if (-not $name) { $name = [string](Get-Prop $meta 'name') }
    if (-not $name) { $name = $f.BaseName }
    $actionMeta = Get-Prop $meta 'ActionMetadata'
    $start = [string](Get-Prop $doc 'StartAction')

    $ids = @{}
    $i = 0
    foreach ($a in $actions) { $i++; $ids[[string](Get-Prop $a 'Identifier')] = "n$i" }

    $blocks = @(); $edges = @()
    $i = 0
    foreach ($a in $actions) {
        $i++
        $id = [string](Get-Prop $a 'Identifier')
        $m = Get-Mapping $a (Get-Prop $actionMeta $id)
        $blocks += [pscustomobject]@{
            Index = $i; Start = ($id -eq $start); Type = $m.Type; Element = $m.Element; Detail = $m.Detail
            Gaps = $m.Gaps; Category = $m.Category; Lambda = $m.Lambda; Target = $m.Target; Secrets = $m.Secrets
        }
        $tr = Get-Prop $a 'Transitions'
        $next = [string](Get-Prop $tr 'NextAction')
        if ($next -and $ids.ContainsKey($next)) { $edges += @{ From = "n$i"; To = $ids[$next]; Label = '' } }
        foreach ($c in @(Get-Prop $tr 'Conditions')) {
            if (-not $c) { continue }
            $to = [string](Get-Prop $c 'NextAction')
            $ops = @(Get-Prop (Get-Prop $c 'Condition') 'Operands') -join ','
            if ($to -and $ids.ContainsKey($to)) { $edges += @{ From = "n$i"; To = $ids[$to]; Label = (Protect-Text $ops) } }
        }
        foreach ($e in @(Get-Prop $tr 'Errors')) {
            if (-not $e) { continue }
            $to = [string](Get-Prop $e 'NextAction')
            if ($to -and $ids.ContainsKey($to)) { $edges += @{ From = "n$i"; To = $ids[$to]; Label = [string](Get-Prop $e 'ErrorType') } }
        }
    }
    $flows += [pscustomobject]@{ Name = (Protect-Text $name); File = $f.Name; Blocks = $blocks; Edges = $edges }
}

# ---------- summarise ----------
$allBlocks = @($flows | ForEach-Object { $_.Blocks })
$prompts = @($allBlocks | Where-Object { $_.Category -eq 'prompt' })
$menus = @($prompts | Where-Object { $_.Element -like '*keypad menu*' })
$entries = @($prompts | Where-Object { $_.Element -like '*digit entry*' })
$lambdas = @{}
foreach ($fl in $flows) {
    foreach ($b in $fl.Blocks | Where-Object { $_.Lambda }) {
        $n = $b.Lambda.Name
        if (-not $lambdas.ContainsKey($n)) { $lambdas[$n] = @{ Flows = @(); Inputs = @() } }
        if ($lambdas[$n].Flows -notcontains $fl.Name) { $lambdas[$n].Flows += $fl.Name }
        foreach ($in in $b.Lambda.Inputs) { if ($lambdas[$n].Inputs -notcontains $in) { $lambdas[$n].Inputs += $in } }
    }
}
$gapRows = @()
foreach ($fl in $flows) { foreach ($b in $fl.Blocks) { foreach ($g in $b.Gaps) { $gapRows += [pscustomobject]@{ Flow = $fl.Name; Block = $b.Index; Type = $b.Type; Gap = $g } } } }
$secretRows = @()
foreach ($fl in $flows) { foreach ($b in $fl.Blocks) { foreach ($s in $b.Secrets) { if ($s) { $secretRows += [pscustomobject]@{ Flow = $fl.Name; Block = $b.Index; Type = $b.Type; Attribute = $s } } } } }
$exported = @($flows | ForEach-Object { $_.Name })
$missing = @($allBlocks | Where-Object { $_.Category -eq 'subflow' -and $_.Target -and ($exported -notcontains $_.Target) } | ForEach-Object { $_.Target } | Select-Object -Unique)

if ($Json) {
    [pscustomobject]@{
        files = $files.Count; flows = $flows; skipped = $skipped
        lambdas = @($lambdas.Keys | ForEach-Object { [pscustomobject]@{ name = $_; flows = $lambdas[$_].Flows; inputs = $lambdas[$_].Inputs } })
        gaps = $gapRows; secrets = $secretRows; missingSubflows = $missing; masked = $script:masked
    } | ConvertTo-Json -Depth 8
    return
}

$out = New-Object System.Collections.Generic.List[string]
$out.Add('# Amazon Connect inventory')
$out.Add('')
$out.Add("Read $($files.Count) file(s): **$($flows.Count) flows**, $($allBlocks.Count) blocks, **$($prompts.Count) prompts** ($($menus.Count) keypad menus, $($entries.Count) digit entries), **$($lambdas.Count) Lambda functions**, **$($gapRows.Count) gaps**.")
$out.Add('')
$out.Add('> Generated by Get-ConnectInventory.ps1 (read-only). Phone numbers, emails, AWS account Ids and key-like strings are masked; attribute values are never shown. Review before sharing.')
$out.Add('')
$out.Add('## Flows')
$out.Add('')
$out.Add('| Flow | Blocks | Prompts | Lambdas | Transfers | Queue steps | Subflows | Gaps |')
$out.Add('|---|---|---|---|---|---|---|---|')
foreach ($fl in $flows) {
    $c = { param($cat) @($fl.Blocks | Where-Object { $_.Category -eq $cat }).Count }
    $g = @($fl.Blocks | ForEach-Object { $_.Gaps } | Where-Object { $_ }).Count
    $out.Add("| $(Format-Cell $fl.Name 60) | $($fl.Blocks.Count) | $(& $c 'prompt') | $(& $c 'lambda') | $(& $c 'transfer') | $(& $c 'queue') | $(& $c 'subflow') | $g |")
}
$out.Add('')
$out.Add('## Lambda functions -> Apex invocables')
$out.Add('')
if ($lambdas.Count) {
    $out.Add('| Lambda | Called from | Inputs | Becomes |')
    $out.Add('|---|---|---|---|')
    foreach ($n in ($lambdas.Keys | Sort-Object)) {
        $out.Add("| $(Format-Cell $n 50) | $(Format-Cell ($lambdas[$n].Flows -join ', ') 60) | $(Format-Cell ($lambdas[$n].Inputs -join ', ') 60) | Apex ``@InvocableMethod`` label ``Voice: <Action>``, result code + speech |")
    }
} else { $out.Add('No Lambda calls found.') }
$out.Add('')
if ($missing.Count) {
    $out.Add('## Subflows referenced but not in the export')
    $out.Add('')
    foreach ($m in $missing) { $out.Add("- $m") }
    $out.Add('')
}
$out.Add('## Gaps to decide with the business')
$out.Add('')
if ($gapRows.Count) {
    $out.Add('| Flow | Block | Connect type | Gap |')
    $out.Add('|---|---|---|---|')
    foreach ($g in $gapRows) { $out.Add("| $(Format-Cell $g.Flow 50) | $($g.Block) | $($g.Type) | $(Format-Cell $g.Gap 140) |") }
} else { $out.Add('None found by the script. Still review the mapping list in references/mapping.md.') }
$out.Add('')
foreach ($fl in $flows) {
    $out.Add("## $(Format-Cell $fl.Name 80)")
    $out.Add('')
    $out.Add("Source file: ``$($fl.File)``")
    $out.Add('')
    $out.Add('| # | Connect block | Salesforce element | Detail |')
    $out.Add('|---|---|---|---|')
    foreach ($b in $fl.Blocks) {
        $mark = $(if ($b.Start) { ' (start)' } else { '' })
        $out.Add("| $($b.Index)$mark | $($b.Type) | $(Format-Cell $b.Element 90) | $(Format-Cell $b.Detail 120) |")
    }
    $out.Add('')
    if ($Mermaid) {
        $out.Add('```mermaid')
        $out.Add('flowchart TD')
        foreach ($b in $fl.Blocks) {
            $label = Get-MermaidLabel ("$($b.Index). $($b.Type)" + $(if ($b.Detail) { ': ' + $b.Detail } else { '' }))
            $out.Add("  n$($b.Index)[""$label""]")
        }
        foreach ($e in $fl.Edges) {
            if ($e.Label) { $out.Add("  $($e.From) -->|$(Get-MermaidLabel $e.Label)| $($e.To)") } else { $out.Add("  $($e.From) --> $($e.To)") }
        }
        $out.Add('```')
        $out.Add('')
    }
}
$out.Add('## Data safety')
$out.Add('')
$out.Add("Masked in this report: $($script:masked.phone) phone number(s), $($script:masked.email) email(s), $($script:masked.awsAccount) AWS account Id(s), $($script:masked.keyLike) key-like string(s).")
if ($secretRows.Count) {
    $out.Add('')
    $out.Add("**$($secretRows.Count) literal secret(s) found** (location only, value never shown). Move each to a Named/External Credential and rotate it; the Apex replacement must not take it as an input.")
    $out.Add('')
    $out.Add('| Flow | Block | Connect type | Attribute |')
    $out.Add('|---|---|---|---|')
    foreach ($s in $secretRows) { $out.Add("| $(Format-Cell $s.Flow 50) | $($s.Block) | $($s.Type) | $($s.Attribute) |") }
}
if ($script:masked.keyLike -gt 0) { $out.Add('Key-like strings were found in the exports: find them in the source files, move them to Named/External Credentials and rotate them.') }
if ($skipped.Count) {
    $out.Add('')
    $out.Add('Skipped files:')
    foreach ($s in $skipped) { $out.Add("- $s") }
}

$text = $out -join [Environment]::NewLine
if ($OutFile) {
    [IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $OutFile ($($flows.Count) flows, $($prompts.Count) prompts, $($lambdas.Count) Lambdas, $($gapRows.Count) gaps)."
} else {
    $text
}
