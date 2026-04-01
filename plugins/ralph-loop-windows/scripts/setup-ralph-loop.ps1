param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Stderr {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Exit-WithError {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        Write-Stderr $line
    }

    exit 1
}

function Show-Help {
    @'
Ralph Loop - Interactive self-referential development loop

USAGE:
  /ralph-loop [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Initial prompt to start the loop (can be multiple words without quotes)

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: unlimited)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  -h, --help                     Show this help message

DESCRIPTION:
  Starts a Ralph Loop in your CURRENT session. The stop hook prevents
  exit and feeds your output back as input until completion or iteration limit.

  To signal completion, you must output: <promise>YOUR_PHRASE</promise>

  Use this for:
  - Interactive iteration where you want to see progress
  - Tasks requiring self-correction and refinement
  - Learning how Ralph works

EXAMPLES:
  /ralph-loop Build a todo API --completion-promise 'DONE' --max-iterations 20
  /ralph-loop --max-iterations 10 Fix the auth bug
  /ralph-loop Refactor cache layer  (runs forever)
  /ralph-loop --completion-promise 'TASK COMPLETE' Create a REST API

STOPPING:
  Only by reaching --max-iterations or detecting --completion-promise
  No manual stop - Ralph runs infinitely by default!

MONITORING:
  # View current iteration:
  Select-String '^iteration:' .claude/ralph-loop.local.md

  # View full state:
  Get-Content .claude/ralph-loop.local.md | Select-Object -First 10
'@
}

function Format-YamlString {
    param([string]$Value)

    '"' + $Value.Replace('\', '\\').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t').Replace('"', '\"') + '"'
}

$promptParts = [System.Collections.Generic.List[string]]::new()
$maxIterations = 0
$completionPromise = $null
$index = 0

while ($index -lt $RemainingArguments.Count) {
    $argument = $RemainingArguments[$index]

    switch ($argument) {
        '-h' {
            Show-Help
            exit 0
        }
        '--help' {
            Show-Help
            exit 0
        }
        '--max-iterations' {
            if ($index + 1 -ge $RemainingArguments.Count) {
                Exit-WithError @(
                    '❌ Error: --max-iterations requires a number argument',
                    '',
                    '   Valid examples:',
                    '     --max-iterations 10',
                    '     --max-iterations 50',
                    '     --max-iterations 0  (unlimited)',
                    '',
                    '   You provided: --max-iterations (with no number)'
                )
            }

            $value = $RemainingArguments[$index + 1]
            if ($value -notmatch '^[0-9]+$') {
                Exit-WithError @(
                    "❌ Error: --max-iterations must be a positive integer or 0, got: $value",
                    '',
                    '   Valid examples:',
                    '     --max-iterations 10',
                    '     --max-iterations 50',
                    '     --max-iterations 0  (unlimited)',
                    '',
                    '   Invalid: decimals (10.5), negative numbers (-5), text'
                )
            }

            $maxIterations = [int]$value
            $index += 2
            continue
        }
        '--completion-promise' {
            if ($index + 1 -ge $RemainingArguments.Count) {
                Exit-WithError @(
                    '❌ Error: --completion-promise requires a text argument',
                    '',
                    '   Valid examples:',
                    "     --completion-promise 'DONE'",
                    "     --completion-promise 'TASK COMPLETE'",
                    "     --completion-promise 'All tests passing'",
                    '',
                    '   You provided: --completion-promise (with no text)',
                    '',
                    '   Note: Multi-word promises must be quoted!'
                )
            }

            $completionPromise = $RemainingArguments[$index + 1]
            $index += 2
            continue
        }
        default {
            $null = $promptParts.Add($argument)
            $index += 1
        }
    }
}

$prompt = ($promptParts.ToArray() -join ' ').Trim()
if ([string]::IsNullOrWhiteSpace($prompt)) {
    Exit-WithError @(
        '❌ Error: No prompt provided',
        '',
        '   Ralph needs a task description to work on.',
        '',
        '   Examples:',
        '     /ralph-loop Build a REST API for todos',
        '     /ralph-loop Fix the auth bug --max-iterations 20',
        "     /ralph-loop --completion-promise 'DONE' Refactor code",
        '',
        '   For all options: /ralph-loop --help'
    )
}

$claudeDirectory = Join-Path (Get-Location) '.claude'
$null = New-Item -ItemType Directory -Path $claudeDirectory -Force

$statePath = Join-Path $claudeDirectory 'ralph-loop.local.md'
$sessionId = if ($env:CLAUDE_CODE_SESSION_ID) { $env:CLAUDE_CODE_SESSION_ID } else { '' }
$completionPromiseYaml = if ([string]::IsNullOrWhiteSpace($completionPromise)) { 'null' } else { Format-YamlString $completionPromise }
$startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$stateContent = @(
    '---',
    'active: true',
    'iteration: 1',
    "session_id: $sessionId",
    "max_iterations: $maxIterations",
    "completion_promise: $completionPromiseYaml",
    ('started_at: "' + $startedAt + '"'),
    '---',
    '',
    $prompt
) -join "`n"

Set-Content -LiteralPath $statePath -Value $stateContent -Encoding utf8NoBOM

$maxIterationsText = if ($maxIterations -gt 0) { "$maxIterations" } else { 'unlimited' }
$completionPromiseText = if ([string]::IsNullOrWhiteSpace($completionPromise)) {
    'none (runs forever)'
}
else {
    "$completionPromise (ONLY output when TRUE - do not lie!)"
}

Write-Output '🔄 Ralph loop activated in this session!'
Write-Output ''
Write-Output 'Iteration: 1'
Write-Output "Max iterations: $maxIterationsText"
Write-Output "Completion promise: $completionPromiseText"
Write-Output ''
Write-Output 'The stop hook is now active. When you try to exit, the SAME PROMPT will be'
Write-Output "fed back to you. You'll see your previous work in files, creating a"
Write-Output 'self-referential loop where you iteratively improve on the same task.'
Write-Output ''
Write-Output 'To monitor: Get-Content .claude/ralph-loop.local.md | Select-Object -First 10'
Write-Output ''
Write-Output '⚠️  WARNING: This loop cannot be stopped manually! It will run infinitely'
Write-Output '    unless you set --max-iterations or --completion-promise.'
Write-Output ''
Write-Output '🔄'

Write-Output ''
Write-Output $prompt

if (-not [string]::IsNullOrWhiteSpace($completionPromise)) {
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════════════════'
    Write-Output 'CRITICAL - Ralph Loop Completion Promise'
    Write-Output '═══════════════════════════════════════════════════════════'
    Write-Output ''
    Write-Output 'To complete this loop, output this EXACT text:'
    Write-Output "  <promise>$completionPromise</promise>"
    Write-Output ''
    Write-Output 'STRICT REQUIREMENTS (DO NOT VIOLATE):'
    Write-Output '  ✓ Use <promise> XML tags EXACTLY as shown above'
    Write-Output '  ✓ The statement MUST be completely and unequivocally TRUE'
    Write-Output '  ✓ Do NOT output false statements to exit the loop'
    Write-Output '  ✓ Do NOT lie even if you think you should exit'
    Write-Output ''
    Write-Output 'IMPORTANT - Do not circumvent the loop:'
    Write-Output "  Even if you believe you're stuck, the task is impossible,"
    Write-Output "  or you've been running too long - you MUST NOT output a"
    Write-Output '  false promise statement. The loop is designed to continue'
    Write-Output '  until the promise is GENUINELY TRUE. Trust the process.'
    Write-Output ''
    Write-Output '  If the loop should stop, the promise statement will become'
    Write-Output '  true naturally. Do not force it by lying.'
    Write-Output '═══════════════════════════════════════════════════════════'
}
