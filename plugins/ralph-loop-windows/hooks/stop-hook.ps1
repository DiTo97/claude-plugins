Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Stderr {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Remove-StateFile {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Stop-RalphLoop {
    param(
        [string]$StatePath,
        [string[]]$WarningLines = @()
    )

    foreach ($line in $WarningLines) {
        Write-Stderr $line
    }

    Remove-StateFile -Path $StatePath
    exit 0
}

function Unquote-YamlScalar {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $trimmed = $Value.Trim()
    if ($trimmed -eq '' -or $trimmed -eq 'null') {
        return $null
    }

    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        $inner = $trimmed.Substring(1, $trimmed.Length - 2)
        return $inner.Replace('\\', '\').Replace('\"', '"')
    }

    return $trimmed
}

function Get-StateData {
    param([string]$Path)

    $rawContent = Get-Content -LiteralPath $Path -Raw
    $normalizedContent = $rawContent -replace "`r`n?", "`n"

    if ($normalizedContent -notmatch '(?s)^---\n(.*?)\n---\n?(.*)$') {
        return $null
    }

    $frontmatterText = $Matches[1]
    $promptText = $Matches[2].TrimStart("`n")
    $values = @{}

    foreach ($line in ($frontmatterText -split "`n")) {
        if ($line -match '^(?<key>[^:]+):\s*(?<value>.*)$') {
            $values[$Matches['key'].Trim()] = $Matches['value'].Trim()
        }
    }

    return @{
        Content = $normalizedContent
        FrontmatterText = $frontmatterText
        Prompt = $promptText
        Values = $values
    }
}

$hookInput = [Console]::In.ReadToEnd()
$statePath = Join-Path (Join-Path (Get-Location) '.claude') 'ralph-loop.local.md'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    exit 0
}

$stateData = Get-StateData -Path $statePath
if ($null -eq $stateData) {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: State file corrupted',
        "   File: $statePath",
        '   Problem: Unable to parse markdown frontmatter',
        '',
        '   Ralph loop is stopping. Run /ralph-loop again to start fresh.'
    )
}

try {
    $hookPayload = if ([string]::IsNullOrWhiteSpace($hookInput)) { $null } else { $hookInput | ConvertFrom-Json -Depth 100 }
}
catch {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: Failed to parse hook input JSON',
        "   Error: $($_.Exception.Message)",
        '   This is unusual and may indicate a Claude Code internal issue.',
        '   Ralph loop is stopping.'
    )
}

$values = $stateData.Values
$iteration = [string]($values['iteration'])
$maxIterations = [string]($values['max_iterations'])
$completionPromise = Unquote-YamlScalar -Value $values['completion_promise']
$stateSession = Unquote-YamlScalar -Value $values['session_id']
$hookSession = if ($null -ne $hookPayload -and $null -ne $hookPayload.session_id) { [string]$hookPayload.session_id } else { '' }

if (-not [string]::IsNullOrWhiteSpace($stateSession) -and $stateSession -cne $hookSession) {
    exit 0
}

if ($iteration -notmatch '^[0-9]+$') {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: State file corrupted',
        "   File: $statePath",
        "   Problem: 'iteration' field is not a valid number (got: '$iteration')",
        '',
        '   This usually means the state file was manually edited or corrupted.',
        '   Ralph loop is stopping. Run /ralph-loop again to start fresh.'
    )
}

if ($maxIterations -notmatch '^[0-9]+$') {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: State file corrupted',
        "   File: $statePath",
        "   Problem: 'max_iterations' field is not a valid number (got: '$maxIterations')",
        '',
        '   This usually means the state file was manually edited or corrupted.',
        '   Ralph loop is stopping. Run /ralph-loop again to start fresh.'
    )
}

$currentIteration = [int]$iteration
$maxIterationCount = [int]$maxIterations

if ($maxIterationCount -gt 0 -and $currentIteration -ge $maxIterationCount) {
    Write-Output "🛑 Ralph loop: Max iterations ($maxIterationCount) reached."
    Remove-StateFile -Path $statePath
    exit 0
}

$transcriptPath = if ($null -ne $hookPayload -and $null -ne $hookPayload.transcript_path) { [string]$hookPayload.transcript_path } else { '' }
if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: Transcript file not found',
        "   Expected: $transcriptPath",
        '   This is unusual and may indicate a Claude Code internal issue.',
        '   Ralph loop is stopping.'
    )
}

$assistantLines = [System.Collections.Generic.Queue[string]]::new()
foreach ($line in Get-Content -LiteralPath $transcriptPath) {
    if ($line -notmatch '"role"\s*:\s*"assistant"') {
        continue
    }

    if ($assistantLines.Count -ge 100) {
        $null = $assistantLines.Dequeue()
    }

    $assistantLines.Enqueue($line)
}

if ($assistantLines.Count -eq 0) {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: No assistant messages found in transcript',
        "   Transcript: $transcriptPath",
        '   This is unusual and may indicate a transcript format issue.',
        '   Ralph loop is stopping.'
    )
}

$lastMessageTextBlocks = [System.Collections.Generic.List[string]]::new()
foreach ($assistantLine in $assistantLines.ToArray()) {
    try {
        $entry = $assistantLine | ConvertFrom-Json -Depth 100
    }
    catch {
        Stop-RalphLoop -StatePath $statePath -WarningLines @(
            '⚠️  Ralph loop: Failed to parse assistant message JSON',
            "   Error: $($_.Exception.Message)",
            '   This may indicate a transcript format issue.',
            '   Ralph loop is stopping.'
        )
    }

    if ('message' -notin $entry.PSObject.Properties.Name) {
        continue
    }

    $message = $entry.message
    if ($null -eq $message -or 'content' -notin $message.PSObject.Properties.Name -or $null -eq $message.content) {
        continue
    }

    $currentBlocks = [System.Collections.Generic.List[string]]::new()
    $contentBlocks = $message.content
    foreach ($block in $contentBlocks) {
        if ($null -ne $block -and $block.type -eq 'text') {
            $null = $currentBlocks.Add([string]$block.text)
        }
    }

    if ($currentBlocks.Count -gt 0) {
        $lastMessageTextBlocks = $currentBlocks
    }
}

$lastOutput = if ($lastMessageTextBlocks.Count -gt 0) { $lastMessageTextBlocks -join "`n" } else { '' }

if (-not [string]::IsNullOrWhiteSpace($completionPromise)) {
    $promiseMatch = [regex]::Match($lastOutput, '(?s)<promise>(.*?)</promise>')
    if ($promiseMatch.Success) {
        $promiseText = ($promiseMatch.Groups[1].Value -replace '\s+', ' ').Trim()
        if ($promiseText -ceq $completionPromise) {
            Write-Output "✅ Ralph loop: Detected <promise>$completionPromise</promise>"
            Remove-StateFile -Path $statePath
            exit 0
        }
    }
}

$promptText = $stateData.Prompt
if ([string]::IsNullOrWhiteSpace($promptText)) {
    Stop-RalphLoop -StatePath $statePath -WarningLines @(
        '⚠️  Ralph loop: State file corrupted or incomplete',
        "   File: $statePath",
        '   Problem: No prompt text found',
        '',
        '   Ralph loop is stopping. Run /ralph-loop again to start fresh.'
    )
}

$nextIteration = $currentIteration + 1
$updatedFrontmatter = $stateData.FrontmatterText -replace '(?m)^iteration:\s*\d+\s*$', "iteration: $nextIteration"
$updatedStateContent = @(
    '---',
    $updatedFrontmatter,
    '---',
    '',
    $promptText
) -join "`n"
$tempStatePath = "$statePath.tmp.$PID"
Set-Content -LiteralPath $tempStatePath -Value $updatedStateContent -Encoding utf8NoBOM
Move-Item -LiteralPath $tempStatePath -Destination $statePath -Force

$systemMessage = if (-not [string]::IsNullOrWhiteSpace($completionPromise)) {
    "🔄 Ralph iteration $nextIteration | To stop: output <promise>$completionPromise</promise> (ONLY when statement is TRUE - do not lie to exit!)"
}
else {
    "🔄 Ralph iteration $nextIteration | No completion promise set - loop runs infinitely"
}

@{
    decision = 'block'
    reason = $promptText
    systemMessage = $systemMessage
} | ConvertTo-Json -Compress
