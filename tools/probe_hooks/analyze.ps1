# Summarize [probe] lines from DST client_log.txt and print a verdict.
# ASCII only on purpose: Windows PowerShell 5.1 reads UTF-8-without-BOM as ANSI,
# so Chinese literals in this file would be garbled. Chinese docs live in README.md.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\analyze.ps1
#   powershell -ExecutionPolicy Bypass -File .\analyze.ps1 -LogPath "D:\...\client_log.txt"

param(
    [string]$LogPath = (Join-Path $env:USERPROFILE 'Documents\Klei\DoNotStarveTogether\client_log.txt')
)

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Host "LOG NOT FOUND: $LogPath" -ForegroundColor Red
    Write-Host "Pass the real path with -LogPath, e.g. -LogPath 'C:\Users\me\Documents\Klei\DoNotStarveTogether\client_log.txt'"
    exit 1
}

$probe = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_ -match '\[probe\]' })

if ($probe.Count -eq 0) {
    Write-Host "No [probe] lines in: $LogPath" -ForegroundColor Red
    Write-Host "Check: 1) mod enabled in the Mods screen  2) you entered a world  3) this is the log of the run you just did"
    exit 1
}

function Count-Of([string]$pattern) {
    $n = 0
    foreach ($line in $probe) {
        if ($line -match $pattern) { $n = $n + 1 }
    }
    return $n
}

$a  = Count-Of 'A\.rpc'
$b  = Count-Of 'B\.thenet'
$c1 = Count-Of 'C\.onsay'
$c2 = Count-Of 'C\.listener'
$c3 = Count-Of 'C\.chatqueue'
$d  = Count-Of 'D\.chatinput'

$selfHits  = Count-Of 'C\.listener .*is_self=true'
$otherHits = Count-Of 'C\.listener .*is_self=false'
$whispers  = Count-Of 'whisper=true'

Write-Host ''
Write-Host '=== hook hits ===' -ForegroundColor Cyan
Write-Host ("{0,-4} {1}" -f 'A', "SendRPCToServer(RPC.Say)                : $a")
Write-Host ("{0,-4} {1}" -f 'B', "TheNet:Say proxy                        : $b")
Write-Host ("{0,-4} {1}" -f 'C1', "ChatHistory.OnSay                       : $c1")
Write-Host ("{0,-4} {1}" -f 'C2', "ChatHistory listener (AddChatHistory..) : $c2")
Write-Host ("{0,-4} {1}" -f 'C3', "chat queue AddChatLine                  : $c3")
Write-Host ("{0,-4} {1}" -f 'D', "ChatInputScreen pre-send                : $d")
Write-Host ''
Write-Host ("self messages (C2 is_self=true) : $selfHits")
Write-Host ("other messages (C2 is_self=false): $otherHits")
Write-Host ("lines with whisper=true          : $whispers")

Write-Host ''
Write-Host '=== verdict ===' -ForegroundColor Cyan

if ($c2 -gt 0) {
    Write-Host 'RECEIVE SIDE OK: ChatHistory listener works -> primary hook = C2 (listener).' -ForegroundColor Green
} elseif ($c1 -gt 0 -or $c3 -gt 0) {
    Write-Host 'RECEIVE SIDE PARTIAL: listener missing, but C1/C3 hit -> wrap OnSay or AddChatLine.' -ForegroundColor Yellow
} else {
    Write-Host 'NO receive-side hit: ChatHistory path changed -> fall back to D (pre-send).' -ForegroundColor Yellow
}

if ($a -gt 0) {
    Write-Host 'SEND SIDE OK: RPC.Say passes through the Lua SendRPCToServer wrapper -> A is viable.' -ForegroundColor Green
} else {
    Write-Host 'SEND SIDE: no RPC.Say hit -> chat does NOT go through Lua SendRPCToServer (plan 2-5 risk confirmed).' -ForegroundColor Yellow
}

if ($d -gt 0) {
    Write-Host 'UI SIDE OK: ChatInputScreen pre-send hit -> raw text + whisper flag available before sending.' -ForegroundColor Green
} else {
    Write-Host 'UI SIDE: no ChatInputScreen hit -> check the "D.class" line for the real method names.' -ForegroundColor Yellow
}

if ($b -gt 0 -and $a -eq 0 -and $d -eq 0) {
    Write-Host 'ONLY B hits: only the invasive TheNet proxy works -> reconsider the design before shipping.' -ForegroundColor Magenta
}

if ($selfHits -gt 0) {
    Write-Host 'SELF ID OK: own message is identifiable on the receive side (userid matches).' -ForegroundColor Green
}
if ($whispers -gt 0) {
    Write-Host 'WHISPER FLAG OK: whisper=true is readable, so the global-only filter is implementable.' -ForegroundColor Green
} else {
    Write-Host 'WHISPER FLAG: no whisper=true seen -> did you run the WHISPER test?' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== last 40 [probe] lines ===' -ForegroundColor Cyan
foreach ($line in @($probe | Select-Object -Last 40)) {
    Write-Host $line
}
