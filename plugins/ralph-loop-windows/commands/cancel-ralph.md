---
description: "Cancel active Ralph Loop"
allowed-tools: ["Bash(pwsh -NoLogo -NoProfile -Command Test-Path .claude/ralph-loop.local.md:*)", "Bash(pwsh -NoLogo -NoProfile -Command Remove-Item .claude/ralph-loop.local.md -Force:*)", "Read(.claude/ralph-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel Ralph

To cancel the Ralph loop:

1. Check if `.claude/ralph-loop.local.md` exists using PowerShell: `pwsh -NoLogo -NoProfile -Command Test-Path .claude/ralph-loop.local.md`

2. **If the command outputs `False`**: Say "No active Ralph loop found."

3. **If the command outputs `True`**:
   - Read `.claude/ralph-loop.local.md` to get the current iteration number from the `iteration:` field
   - Remove the file using PowerShell: `pwsh -NoLogo -NoProfile -Command Remove-Item .claude/ralph-loop.local.md -Force`
   - Report: "Cancelled Ralph loop (was at iteration N)" where N is the iteration value
