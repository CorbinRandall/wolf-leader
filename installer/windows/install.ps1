<#
.SYNOPSIS
  Wolf Leader Windows install steps. Run by WolfLeaderSetup.exe after the wizard; safe to re-run.

.DESCRIPTION
  Reads the answer file (installer/CONFIG.md format) plus the installer-only choices passed as
  switches, then does exactly what CONFIG.md "What install does, by toggle" lists. Before changing
  anything it snapshots every file it will create or overwrite into
  %LOCALAPPDATA%\WolfLeader\backup-<YYYYMMDD-HHMM> (or -BackupDir) next to a restore.ps1.

  Share passwords never arrive on the command line: the setup wizard puts them in the environment
  as WL_SHARE<n>_PASSWORD (n = 1..5), or -SecretsFile points at a "share<n>=password" file that is
  deleted as soon as it has been read. Passwords are never written to the log.

  Lines starting with "@@STEP <percent> " are progress markers the setup wizard shows.

.EXAMPLE
  .\install.ps1 -Config "$env:TEMP\wolf-leader-setup.ini" -Mode connect -Client -Shares -GitName Me -GitEmail me@example.com -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [ValidateSet('new', 'connect', 'update')][string]$Mode = 'connect',
    [switch]$Client,
    [switch]$Shares,
    [switch]$Prereqs,
    [switch]$Obsidian,
    [switch]$Wiki,
    [string]$GitName = '',
    [string]$GitEmail = '',
    [string]$SecretsFile = '',
    [string]$ResultFile = '',
    [string]$Root = '',
    [string]$LogFile = '',
    [string]$BackupDir = '',
    [switch]$ValidateOnly,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$DataDir = Join-Path $env:LOCALAPPDATA 'WolfLeader'
if (-not $LogFile) { $LogFile = Join-Path $DataDir 'install.log' }
if (-not $ResultFile) { $ResultFile = Join-Path $DataDir 'install-result.ini' }

$script:Errors = 0
$script:Warnings = 0
$script:Health = 'skipped'
$script:HealthDetail = ''
$script:VaultPath = ''
$script:BackupPath = ''

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null

function Write-LogLine([string]$Text) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -LiteralPath $LogFile -Value "$stamp  $Text" -Encoding UTF8 } catch { }
}

function Say([string]$Text) {
    [Console]::Out.WriteLine($Text)
    Write-LogLine $Text
}

function Step([int]$Percent, [string]$Text) {
    [Console]::Out.WriteLine("@@STEP $Percent $Text")
    Write-LogLine "== $Text"
}

function Ok([string]$Text) { Say "  OK    $Text" }
function Skip([string]$Text) { Say "  SKIP  $Text" }
function Warn([string]$Text) { $script:Warnings++; Say "  WARN  $Text" }
function Fail([string]$Text) { $script:Errors++; Say "  FAIL  $Text" }
function Plan([string]$Text) { Say "  [dry-run] $Text" }

# ---------------------------------------------------------------------------------------------
# Answer file
# ---------------------------------------------------------------------------------------------

function Read-AnswerFile([string]$Path) {
    $ini = @{}
    $lines = @{}
    $section = ''
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $n++
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line -eq '' -or $line.StartsWith('```') -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($section -eq '') { throw "Line ${n}: '$line' comes before any [section]" }
        if ($eq -lt 1) { throw "Line ${n}: '$line' is not key=value" }
        $key = $line.Substring(0, $eq).Trim().ToLowerInvariant()
        $value = $line.Substring($eq + 1).Trim()
        if ($value -eq '') { throw "Line ${n}: '$line' has an empty value" }
        $ini[$section][$key] = $value
        $lines["$section.$key"] = "Line ${n}: $line"
    }
    return @{ Values = $ini; Lines = $lines }
}

function Get-Ini($Answer, [string]$Section, [string]$Key) {
    $v = $Answer.Values
    if ($v.ContainsKey($Section) -and $v[$Section].ContainsKey($Key)) { return [string]$v[$Section][$Key] }
    return ''
}

function Test-AnswerFile($Answer) {
    $bad = {
        param($Section, $Key, $Why)
        $where = $Answer.Lines["$Section.$Key"]
        if (-not $where) { $where = "[$Section] $Key is missing" }
        throw "$where -- $Why"
    }
    $yesNo = '^(?i)(yes|no)$'

    if ((Get-Ini $Answer 'wolf' 'format') -ne '1') { & $bad 'wolf' 'format' 'format must be 1' }
    if ((Get-Ini $Answer 'wolf' 'os') -ne 'windows') { & $bad 'wolf' 'os' 'os must be windows (this is the Windows installer)' }
    foreach ($k in 'hub_url', 'mcp_url') {
        if ((Get-Ini $Answer 'wolf' $k) -notmatch '^https?://\S+$') { & $bad 'wolf' $k "$k must start with http:// or https://" }
    }
    if ((Get-Ini $Answer 'wolf' 'timezone') -notmatch '^[A-Za-z0-9/_+-]+$') { & $bad 'wolf' 'timezone' 'timezone must be an IANA zone like America/Chicago' }
    if ((Get-Ini $Answer 'wolf' 'device_name') -notmatch '^[A-Za-z0-9-]{1,32}$') { & $bad 'wolf' 'device_name' 'device_name must be 1-32 letters, digits or hyphens' }

    foreach ($k in 'git', 'python', 'docker', 'obsidian', 'cursor', 'claude_code', 'wolf_client') {
        if ((Get-Ini $Answer 'detected' $k) -notmatch $yesNo) { & $bad 'detected' $k "$k must be yes or no" }
    }
    if ((Get-Ini $Answer 'detected' 'python_version') -notmatch '^(NONE|\d+(\.\d+)*)$') { & $bad 'detected' 'python_version' 'python_version must be like 3.13.1 or NONE' }

    $done = Get-Ini $Answer 'backup' 'done'
    if ($done -notmatch $yesNo) { & $bad 'backup' 'done' 'done must be yes or no' }
    $bpath = Get-Ini $Answer 'backup' 'path'
    if ($bpath -cne 'NONE' -and $bpath -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\)') { & $bad 'backup' 'path' 'path must be an absolute folder like C:\Users\me\WolfLeader-backup-20261006-1240, or NONE' }
    if ($done -ieq 'yes' -and $bpath -ceq 'NONE') { & $bad 'backup' 'path' 'done=yes needs the backup folder path' }
    if ((Get-Ini $Answer 'backup' 'files') -notmatch '^\d+$') { & $bad 'backup' 'files' 'files must be digits only' }

    foreach ($i in 1..5) {
        $s = "share$i"
        if (-not $Answer.Values.ContainsKey($s)) { continue }
        if ((Get-Ini $Answer $s 'unc') -notmatch '^\\\\[^\\]+\\[^\\].*$') { & $bad $s 'unc' 'unc must look like \\server\share' }
        if ((Get-Ini $Answer $s 'letter') -notmatch '^(?i)[A-Z]$') { & $bad $s 'letter' 'letter must be one drive letter A-Z, no colon' }
        if ((Get-Ini $Answer $s 'user') -eq '') { & $bad $s 'user' 'user must be a username or NONE' }
        if ((Get-Ini $Answer $s 'password') -notmatch '^(ASK|NONE)$') { & $bad $s 'password' 'password must be ASK or NONE (never a real password)' }
        if ((Get-Ini $Answer $s 'role') -notmatch '^(?i)(wolf|extra)$') { & $bad $s 'role' 'role must be wolf or extra' }
        $smb = Get-Ini $Answer $s 'smb_url'
        if ($smb -and $smb -notmatch '^(NONE|smb://\S+)$') { & $bad $s 'smb_url' 'smb_url must be NONE or smb://server/share' }
    }
}

function Test-Yes($Answer, [string]$Key) { return ((Get-Ini $Answer 'detected' $Key) -ieq 'yes') }

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Invoke-Native([string]$Exe, [string[]]$ArgList, [switch]$Quiet) {
    if ($DryRun) { Plan "$Exe $($ArgList -join ' ')"; return 0 }
    if (-not (Test-Command $Exe)) { Say "        $Exe was not found"; return 9009 }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object {
            $t = "$_".TrimEnd()
            # winget/docker progress spinners and bars are noise in the log
            if (-not $Quiet -and $t -and $t -notmatch '^\s*[-\\|/]\s*$' -and $t -notmatch '[\u2580-\u259F]') { Say "        $t" }
        }
        return $LASTEXITCODE
    } catch {
        Say "        $($_.Exception.Message)"
        return 1
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-NativeOutput([string]$Exe, [string[]]$ArgList) {
    if (-not (Test-Command $Exe)) { return '' }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Exe @ArgList 2>$null | Out-String).Trim() } catch { return '' } finally { $ErrorActionPreference = $old }
}

function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Write-TextFile([string]$Path, [string]$Text) {
    if ($DryRun) { Plan "write $Path"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Copy-Tree([string]$From, [string]$To) {
    if (-not (Test-Path -LiteralPath $From)) { Fail "missing $From (installer bundle incomplete)"; return }
    $count = 0
    $base = (Resolve-Path -LiteralPath $From).Path.TrimEnd('\')
    foreach ($f in Get-ChildItem -LiteralPath $From -Recurse -File) {
        if ($f.FullName -match '\\__pycache__\\' -or $f.Extension -eq '.pyc') { continue }
        $rel = $f.FullName.Substring($base.Length + 1)
        $dest = Join-Path $To $rel
        if ($DryRun) { Plan "copy $rel -> $dest" }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        $count++
    }
    Ok "$count files -> $To"
}

$WingetOkCodes = @(0, -1978335189, -1978335135)   # ok, no applicable upgrade, already installed

function Install-WithWinget([string]$Id, [string]$Label) {
    if (-not $DryRun -and -not (Test-Command 'winget')) {
        Fail "$Label is missing and winget is not available. Install it by hand, then re-run setup."
        return $false
    }
    Say "  ...   installing $Label with winget (a Windows permission prompt may appear)"
    $code = Invoke-Native 'winget' @('install', '-e', '--id', $Id, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($WingetOkCodes -contains $code) {
        if (-not $DryRun) { Update-SessionPath }
        Ok "$Label installed"
        return $true
    }
    Fail "winget could not install $Label (exit $code)"
    return $false
}

function Get-PythonVersion {
    foreach ($c in 'python', 'py') {
        if (-not (Test-Command $c)) { continue }
        $v = Get-NativeOutput $c @('--version')
        if ($v -match 'Python (3\.\d+(\.\d+)?)') { return $Matches[1] }
    }
    return ''
}

function Find-Obsidian {
    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'),
        (Join-Path $env:LOCALAPPDATA 'Obsidian\Obsidian.exe'),
        (Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe')
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}

function Get-SharePassword([int]$Index) {
    $name = "WL_SHARE${Index}_PASSWORD"
    $v = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($v) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        return $v
    }
    if ($script:Secrets.ContainsKey("share$Index")) { return $script:Secrets["share$Index"] }
    return ''
}

$CredSource = @'
using System;
using System.Runtime.InteropServices;
public static class WolfCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL credential, int flags);
    // Same record "cmdkey /add:<server> /user:<u> /pass:<p>" creates, without the password on a command line.
    public static void Add(string target, string user, string password) {
        byte[] blob = System.Text.Encoding.Unicode.GetBytes(password ?? "");
        CREDENTIAL c = new CREDENTIAL();
        c.Type = 2; c.Persist = 3; c.TargetName = target; c.UserName = user;
        c.CredentialBlobSize = blob.Length;
        c.CredentialBlob = Marshal.AllocHGlobal(Math.Max(blob.Length, 2));
        try {
            Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally {
            for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(c.CredentialBlob, i, 0);
            Marshal.FreeHGlobal(c.CredentialBlob);
            Array.Clear(blob, 0, blob.Length);
        }
    }
}
'@

function Add-ShareCredential([string]$Server, [string]$User, [string]$Password) {
    if ($DryRun) { Plan "cmdkey /add:$Server /user:$User /pass:<hidden>  (stored with CredWrite, same as cmdkey)"; return $true }
    if (-not ('WolfCred' -as [type])) { Add-Type -TypeDefinition $CredSource -Language CSharp }
    try { [WolfCred]::Add($Server, $User, $Password); return $true }
    catch { Fail "could not save the credential for $Server ($($_.Exception.Message))"; return $false }
}

function Set-EnvKey([System.Collections.Generic.List[string]]$Lines, [string]$Key, [string]$Value) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*#?\s*$([regex]::Escape($Key))=") { $Lines[$i] = "$Key=$Value"; return }
    }
    $Lines.Add("$Key=$Value")
}

# ---------------------------------------------------------------------------------------------
# Save state before install
# ---------------------------------------------------------------------------------------------

function Get-PlannedTargets($Answer) {
    $t = New-Object 'System.Collections.Generic.List[string]'
    $cursor = Join-Path $env:USERPROFILE '.cursor'
    $skillSrc = Join-Path $Root 'examples\cursor\skills'
    $skillNames = @('save', 'new', 'wolfhowl', 'wolfeat')
    if (Test-Path -LiteralPath $skillSrc) { $skillNames = @(Get-ChildItem -LiteralPath $skillSrc -Directory | ForEach-Object { $_.Name }) }
    $skillHomes = @(Join-Path $cursor 'skills')
    if (Test-Yes $Answer 'claude_code') { $skillHomes += (Join-Path $env:USERPROFILE '.claude\skills') }

    if ($Client) {
        foreach ($f in 'mcp.json', 'AGENTS.md', 'wolf-leader.env', 'lib\wolf-leader-client.sh') { $t.Add((Join-Path $cursor $f)) }
        $rulesSrc = Join-Path $Root 'examples\cursor\rules'
        if (Test-Path -LiteralPath $rulesSrc) { foreach ($r in Get-ChildItem -LiteralPath $rulesSrc -File) { $t.Add((Join-Path $cursor "rules\$($r.Name)")) } }
        foreach ($homeDir in $skillHomes) {
            foreach ($name in $skillNames) {
                $dest = Join-Path $homeDir $name
                # everything already in the skill folder, plus every file the copy will add
                if (Test-Path -LiteralPath $dest) { foreach ($f in Get-ChildItem -LiteralPath $dest -Recurse -File) { $t.Add($f.FullName) } }
                $src = Join-Path $skillSrc $name
                if (Test-Path -LiteralPath $src) {
                    $base = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
                    foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File) {
                        if ($f.FullName -match '\\__pycache__\\' -or $f.Extension -eq '.pyc') { continue }
                        $t.Add((Join-Path $dest $f.FullName.Substring($base.Length + 1)))
                    }
                }
            }
        }
    }
    $t.Add((Join-Path $env:USERPROFILE '.gitconfig'))
    if ($Mode -eq 'new' -or $Mode -eq 'update') { $t.Add((Join-Path $Root '.env')) }
    return @($t | Sort-Object -Unique)
}

function Get-BackupRelPath([string]$Path) {
    $homeDir = $env:USERPROFILE.TrimEnd('\')
    $rootDir = $Root.TrimEnd('\')
    if ($Path.StartsWith($homeDir + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'home\' + $Path.Substring($homeDir.Length + 1) }
    if ($Path.StartsWith($rootDir + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'hub\' + $Path.Substring($rootDir.Length + 1) }
    return 'other\' + ($Path -replace '[:\\]+', '_')
}

$RestoreScript = @'
# Undo Wolf Leader setup: puts back every file it changed and removes the files it added.
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<this folder>\restore.ps1"
# Not undone: programs installed with winget, mapped drives and saved share credentials,
# and the hub's Docker containers (stop them with: docker compose -f docker-compose.postgres.yml down).
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$restored = 0; $removed = 0
$manifest = Join-Path $here 'manifest.txt'
if (Test-Path -LiteralPath $manifest) {
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        $parts = $line -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $src = Join-Path $here $parts[0]
        New-Item -ItemType Directory -Force -Path (Split-Path $parts[1]) | Out-Null
        Copy-Item -LiteralPath $src -Destination $parts[1] -Force
        Write-Host "restored $($parts[1])"; $restored++
    }
}
$created = Join-Path $here 'created.txt'
if (Test-Path -LiteralPath $created) {
    foreach ($p in [IO.File]::ReadAllLines($created)) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { Remove-Item -LiteralPath $p -Force; Write-Host "removed $p"; $removed++ }
    }
}
Write-Host "Done: $restored file(s) restored, $removed file(s) removed. Restart Cursor."
'@

function Save-StateBeforeInstall($Answer) {
    Step 5 'Saving a backup of everything setup will change'
    if (-not $BackupDir) {
        $BackupDir = Join-Path $DataDir ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
    }
    if (-not $DryRun -and (Test-Path -LiteralPath (Join-Path $BackupDir 'manifest.txt'))) {
        $n = 2
        while (Test-Path -LiteralPath "$BackupDir-$n") { $n++ }
        $BackupDir = "$BackupDir-$n"
    }
    $script:BackupPath = $BackupDir
    $manifest = New-Object 'System.Collections.Generic.List[string]'
    $created = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in Get-PlannedTargets $Answer) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $rel = Get-BackupRelPath $p
            if ($DryRun) { Plan "back up $p -> $BackupDir\$rel" }
            else {
                $dest = Join-Path $BackupDir $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                Copy-Item -LiteralPath $p -Destination $dest -Force
            }
            $manifest.Add("$rel|$p")
        } else {
            $created.Add($p)
        }
    }
    if ($DryRun) {
        Plan "write $BackupDir\restore.ps1 (+ manifest.txt with $($manifest.Count) saved file(s), created.txt with $($created.Count) new file(s) to remove on restore)"
    } else {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines((Join-Path $BackupDir 'manifest.txt'), [string[]]$manifest, $utf8)
        [IO.File]::WriteAllLines((Join-Path $BackupDir 'created.txt'), [string[]]$created, $utf8)
        [IO.File]::WriteAllText((Join-Path $BackupDir 'restore.ps1'), $RestoreScript, $utf8)
    }
    Ok "backup: $($manifest.Count) file(s) saved to $BackupDir; run restore.ps1 there to undo"

    $agentDone = Get-Ini $Answer 'backup' 'done'
    $agentPath = Get-Ini $Answer 'backup' 'path'
    if ($agentDone -ieq 'yes' -and (Test-Path -LiteralPath $agentPath)) { Say "  NOTE  your agent's backup: $agentPath ($(Get-Ini $Answer 'backup' 'files') files)" }
    elseif ($agentDone -ieq 'yes') { Warn "your agent said it backed up to $agentPath, but that folder does not exist" }
    else { Warn "your agent did not make a backup (done=no); the installer's own backup above covers the files setup changes" }
}

# ---------------------------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------------------------

function Invoke-Prereqs($Answer) {
    Step 10 'Checking Git and Python'
    if ((Test-Yes $Answer 'git') -or (Test-Command 'git')) {
        $why = if (Test-Command 'git') { Get-NativeOutput 'git' @('--version') } else { 'reported by your agent' }
        Skip "Git already installed ($why)"
    } else {
        Install-WithWinget 'Git.Git' 'Git' | Out-Null
    }
    $py = Get-PythonVersion
    if ((Test-Yes $Answer 'python') -or $py) {
        $why = if ($py) { "Python $py" } else { 'reported by your agent' }
        Skip "Python already installed ($why)"
    } else {
        Install-WithWinget 'Python.Python.3.13' 'Python 3.13' | Out-Null
    }
}

function Invoke-Shares($Answer) {
    Step 25 'Mapping network shares'
    $any = $false
    foreach ($i in 1..5) {
        $s = "share$i"
        if (-not $Answer.Values.ContainsKey($s)) { continue }
        $any = $true
        $unc = (Get-Ini $Answer $s 'unc').TrimEnd('\')
        $letter = (Get-Ini $Answer $s 'letter').ToUpperInvariant()
        $user = Get-Ini $Answer $s 'user'
        $pwMode = Get-Ini $Answer $s 'password'
        $server = $unc.TrimStart('\').Split('\')[0]
        $drive = "${letter}:"

        $disk = $null
        try { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop } catch { }
        if ($disk) {
            if ($disk.DriveType -eq 4 -and ([string]$disk.ProviderName).TrimEnd('\') -ieq $unc) { Skip "$drive already mapped to $unc"; continue }
            if ($disk.DriveType -eq 4) { Warn "$drive is already mapped to $($disk.ProviderName); left it alone (wanted $unc)"; continue }
            Warn "$drive is a local drive on this PC; pick another letter for $unc and re-run setup"
            continue
        }
        $remembered = $null
        try { $remembered = (Get-ItemProperty -Path "HKCU:\Network\$letter" -ErrorAction Stop).RemotePath } catch { }
        if ($remembered) {
            if ($remembered.TrimEnd('\') -ine $unc) { Warn "$drive is remembered for $remembered; left it alone (wanted $unc)"; continue }
            Say "  ...   $drive is remembered but disconnected; reconnecting"
            Invoke-Native 'net' @('use', $drive, '/delete', '/y') -Quiet | Out-Null
        }

        if ($user -ine 'NONE') {
            $pw = ''
            if ($pwMode -eq 'ASK') {
                $pw = Get-SharePassword $i
                if (-not $pw -and -not $DryRun) { Warn "no password entered for $unc; Windows will ask when you open $drive" }
            }
            if ($pwMode -eq 'NONE' -or $pw -or $DryRun) {
                if (Add-ShareCredential $server $user $pw) { Ok "credential saved for $server (user $user)" }
            }
            $pw = $null
        }

        # stdin from nul: net use would otherwise sit waiting for a typed password
        $target = if ($unc -match '\s') { "`"$unc`"" } else { $unc }
        $code = Invoke-Native 'cmd.exe' @('/d', '/c', "net use $drive $target /persistent:yes < nul")
        if ($code -eq 0) { Ok "$drive -> $unc" } else { Fail "net use $drive $unc failed (exit $code). Check the server name, user and password." }
    }
    if (-not $any) { Skip 'no [shareN] sections in the answer file' }
}

function Invoke-GitIdentity {
    Step 40 'Setting git identity'
    if (-not $DryRun -and -not (Test-Command 'git')) { Update-SessionPath }
    if (-not $DryRun -and -not (Test-Command 'git')) { Warn 'git is not installed, so git identity and safe.directory were not set'; return }
    if ($GitName -and $GitEmail) {
        $c1 = Invoke-Native 'git' @('config', '--global', 'user.name', $GitName)
        $c2 = Invoke-Native 'git' @('config', '--global', 'user.email', $GitEmail)
        if ($c1 -eq 0 -and $c2 -eq 0) { Ok "git user $GitName <$GitEmail>" } else { Fail 'git config user.name/user.email failed' }
    } else {
        Warn 'no git name/email given; skipped user.name/user.email'
    }
    $safe = if ($DryRun -and -not (Test-Command 'git')) { '' } else { Get-NativeOutput 'git' @('config', '--global', '--get-all', 'safe.directory') }
    if (($safe -split "`r?`n") -contains '*') { Skip "safe.directory '*' already set" }
    else {
        $c = Invoke-Native 'git' @('config', '--global', '--add', 'safe.directory', '*')
        if ($c -eq 0) { Ok "safe.directory '*' (network-share repos work without ownership prompts)" } else { Fail 'git config safe.directory failed' }
    }
}

function Merge-McpJson([string]$Path, [string]$McpUrl) {
    $obj = $null
    if (Test-Path -LiteralPath $Path) {
        $raw = [IO.File]::ReadAllText($Path)
        if ($raw.Trim()) {
            try { $obj = $raw | ConvertFrom-Json }
            catch { Fail "$Path is not valid JSON, so it was left untouched. Add `"wolf-leader`": { `"url`": `"$McpUrl`" } under mcpServers yourself."; return }
        }
    }
    if (-not $obj) { $obj = New-Object PSObject }
    if (-not $obj.PSObject.Properties['mcpServers'] -or -not $obj.mcpServers) {
        $obj | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue (New-Object PSObject) -Force
    }
    $entry = New-Object PSObject -Property @{ url = $McpUrl }
    $obj.mcpServers | Add-Member -NotePropertyName 'wolf-leader' -NotePropertyValue $entry -Force
    $others = @($obj.mcpServers.PSObject.Properties | Where-Object { $_.Name -ne 'wolf-leader' } | ForEach-Object { $_.Name })
    if ($DryRun) {
        Plan "merge mcpServers.wolf-leader = { url = $McpUrl } into $Path (keeps: $(if ($others) { $others -join ', ' } else { 'no other servers' }))"
        return
    }
    Write-TextFile $Path ($obj | ConvertTo-Json -Depth 32)
    Ok "mcp.json: wolf-leader -> $McpUrl (other servers kept: $($others.Count))"
}

function Invoke-Client($Answer) {
    Step 55 'Installing the Cursor / Claude Code client'
    $hub = (Get-Ini $Answer 'wolf' 'hub_url').TrimEnd('/')
    $mcp = Get-Ini $Answer 'wolf' 'mcp_url'
    $cursor = Join-Path $env:USERPROFILE '.cursor'
    $ex = Join-Path $Root 'examples'

    Copy-Tree (Join-Path $ex 'cursor\skills') (Join-Path $cursor 'skills')
    Copy-Tree (Join-Path $ex 'cursor\rules') (Join-Path $cursor 'rules')
    $agents = Join-Path $ex 'AGENTS.md'
    if ($DryRun) { Plan "copy AGENTS.md -> $cursor\AGENTS.md" }
    else { Copy-Item -LiteralPath $agents -Destination (Join-Path $cursor 'AGENTS.md') -Force }
    Ok "AGENTS.md -> $cursor"
    # skills/new/scripts/new-project-session-curl.sh sources ~/.cursor/lib/wolf-leader-client.sh
    $lib = Join-Path $Root 'scripts\lib\wolf-leader-client.sh'
    if (Test-Path -LiteralPath $lib) {
        if ($DryRun) { Plan "copy lib\wolf-leader-client.sh -> $cursor\lib" }
        else {
            New-Item -ItemType Directory -Force -Path (Join-Path $cursor 'lib') | Out-Null
            Copy-Item -LiteralPath $lib -Destination (Join-Path $cursor 'lib\wolf-leader-client.sh') -Force
        }
    }

    Merge-McpJson (Join-Path $cursor 'mcp.json') $mcp
    Write-TextFile (Join-Path $cursor 'wolf-leader.env') ("# Wolf Leader hub URLs, written by the Windows installer. Edit if your hub moves.`nWOLF_LEADER_API=$hub`nWOLF_LEADER_MCP=$mcp`n")
    Ok "wolf-leader.env (API $hub, MCP $mcp)"
    Skip 'hooks (Wolf Leader saves through MCP; no hooks are installed)'
    $hooks = Join-Path $cursor 'hooks.json'
    if ((Test-Path -LiteralPath $hooks) -and ((Get-Content -Raw -LiteralPath $hooks) -match 'wolf-leader-(save|recall)')) {
        Warn "$hooks still lists old Wolf Leader hooks; they are no longer needed and can be removed"
    }

    if (Test-Yes $Answer 'claude_code') {
        Copy-Tree (Join-Path $ex 'cursor\skills') (Join-Path $env:USERPROFILE '.claude\skills')
    } else {
        Skip 'Claude Code skills (claude_code=no)'
    }
}

function Get-WolfShareVault($Answer) {
    foreach ($i in 1..5) {
        $s = "share$i"
        if ((Get-Ini $Answer $s 'role') -ieq 'wolf') {
            $l = Get-Ini $Answer $s 'letter'
            if ($Shares -and $l) { return "$($l.ToUpperInvariant()):\wolf-leader\vault" }
            return ((Get-Ini $Answer $s 'unc').TrimEnd('\') + '\wolf-leader\vault')
        }
    }
    return ''
}

function Invoke-Obsidian($Answer) {
    Step 65 'Checking Obsidian'
    $exe = Find-Obsidian
    if ((Test-Yes $Answer 'obsidian') -or $exe) {
        Skip "Obsidian already installed$(if ($exe) { " ($exe)" })"
    } else {
        Install-WithWinget 'Obsidian.Obsidian' 'Obsidian' | Out-Null
    }
    if ($Mode -eq 'new') { $script:VaultPath = Join-Path $DataDir 'share\wolf-leader\vault' }
    else { $script:VaultPath = Get-WolfShareVault $Answer }
    if ($script:VaultPath) { Say "  NOTE  In Obsidian choose 'Open folder as vault' and pick $($script:VaultPath)" }
    else { Warn 'no role=wolf share in the answer file, so there is no vault folder to point Obsidian at yet' }
}

function Test-DockerReady {
    if (-not (Test-Command 'docker')) {
        return 'Docker is not installed. A new hub runs in Docker: install Docker Desktop (https://www.docker.com/products/docker-desktop/), start it, then run this installer again.'
    }
    if ((Invoke-Native 'docker' @('info') -Quiet) -ne 0 -and -not $DryRun) {
        return 'Docker is installed but not running. Start Docker Desktop, wait until it says "Engine running", then run this installer again.'
    }
    if (-not $DryRun -and (Invoke-Native 'docker' @('compose', 'version') -Quiet) -ne 0) {
        return 'This Docker has no "docker compose". Update Docker Desktop, then run this installer again.'
    }
    return ''
}

function Invoke-Compose {
    Say '  ...   docker compose -f docker-compose.postgres.yml up -d --build (first build takes several minutes)'
    Push-Location $Root
    try { $code = Invoke-Native 'docker' @('compose', '-f', 'docker-compose.postgres.yml', 'up', '-d', '--build') }
    finally { Pop-Location }
    if ($code -eq 0) { Ok 'hub containers are up' } else { Fail "docker compose failed (exit $code); see the lines above" }
    return ($code -eq 0)
}

function Invoke-NewHub($Answer) {
    Step 70 'Setting up the hub on this PC (Docker)'
    $why = Test-DockerReady
    if ($why) { Fail $why; return $false }
    Ok 'Docker is ready'

    $envPath = Join-Path $Root '.env'
    $example = Join-Path $Root '.env.example'
    $shareRoot = Join-Path $DataDir 'share'
    $fresh = -not (Test-Path -LiteralPath $envPath)
    $src = if ($fresh) { $example } else { $envPath }
    if (-not (Test-Path -LiteralPath $src)) { Fail "missing $src (installer bundle incomplete)"; return $false }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in [IO.File]::ReadAllLines($src)) { $lines.Add($l) }

    Set-EnvKey $lines 'IDE_STORAGE_PUBLIC_URL' ((Get-Ini $Answer 'wolf' 'hub_url').TrimEnd('/'))
    Set-EnvKey $lines 'IDE_STORAGE_MCP_URL' (Get-Ini $Answer 'wolf' 'mcp_url')
    Set-EnvKey $lines 'WOLF_TZ' (Get-Ini $Answer 'wolf' 'timezone')
    Set-EnvKey $lines 'WOLF_WIKI_ENABLED' $(if ($Wiki) { '1' } else { '0' })
    Set-EnvKey $lines 'WOLF_SHARE_ROOT' ($shareRoot -replace '\\', '/')
    if ($fresh) {
        $bytes = New-Object byte[] 18
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Set-EnvKey $lines 'POSTGRES_PASSWORD' (([BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant()
    }
    foreach ($d in 'wolf-leader\vault', 'wolf-leader\hub') {
        $p = Join-Path $shareRoot $d
        if ($DryRun) { Plan "mkdir $p" } else { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
    Write-TextFile $envPath (($lines -join "`n") + "`n")
    Ok "$(if ($fresh) { 'created' } else { 'updated' }) $envPath (wiki $(if ($Wiki) { 'on' } else { 'off' }), data in $shareRoot)"
    return (Invoke-Compose)
}

function Invoke-UpdateHub {
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.env'))) { return $false }
    Step 70 'Rebuilding the hub on this PC with the updated files'
    $why = Test-DockerReady
    if ($why) { Warn "hub not rebuilt: $why"; return $false }
    return (Invoke-Compose)
}

function Test-Health([string]$HubUrl, [int]$Seconds) {
    $url = $HubUrl.TrimEnd('/') + '/health'
    if ($DryRun) { Plan "GET $url (wait up to $Seconds s)"; $script:Health = 'dry-run'; return }
    $deadline = (Get-Date).AddSeconds($Seconds)
    $last = ''
    do {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
            if ($r.StatusCode -eq 200) {
                $script:Health = 'ok'
                $script:HealthDetail = "$url answered 200"
                Ok $script:HealthDetail
                return
            }
            $last = "HTTP $($r.StatusCode)"
        } catch { $last = $_.Exception.Message }
        if ((Get-Date) -lt $deadline) { Say "  ...   waiting for $url ($last)"; Start-Sleep -Seconds 10 }
    } while ((Get-Date) -lt $deadline)
    $script:Health = 'fail'
    $script:HealthDetail = "$url did not answer ($last)"
    Fail $script:HealthDetail
}

function Write-Result {
    $text = @(
        '[result]'
        "ok=$(if ($script:Errors -eq 0) { 1 } else { 0 })"
        "errors=$($script:Errors)"
        "warnings=$($script:Warnings)"
        "health=$($script:Health)"
        "health_detail=$($script:HealthDetail)"
        "vault=$($script:VaultPath)"
        "backup=$($script:BackupPath)"
        "log=$LogFile"
    ) -join "`r`n"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $ResultFile) | Out-Null
        # UTF-16 with BOM: the setup wizard reads this with GetIniString (GetPrivateProfileString)
        [IO.File]::WriteAllText($ResultFile, $text + "`r`n", [Text.Encoding]::Unicode)
    } catch { Say "  WARN  could not write $ResultFile" }
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

$script:Secrets = @{}
if ($SecretsFile) {
    if (Test-Path -LiteralPath $SecretsFile) {
        foreach ($l in [IO.File]::ReadAllLines($SecretsFile)) {
            $eq = $l.IndexOf('=')
            if ($eq -gt 0) { $script:Secrets[$l.Substring(0, $eq).Trim().ToLowerInvariant()] = $l.Substring($eq + 1) }
        }
        Remove-Item -LiteralPath $SecretsFile -Force
    }
}

Write-LogLine '------------------------------------------------------------'
$toggles = @()
foreach ($t in 'Client', 'Shares', 'Prereqs', 'Obsidian', 'Wiki') { if ((Get-Variable $t -ValueOnly).IsPresent) { $toggles += $t.ToLowerInvariant() } }
Say "Wolf Leader Windows install$(if ($DryRun) { ' (DRY RUN: nothing is changed)' })"
Say "  mode=$Mode  toggles=$(if ($toggles) { $toggles -join ',' } else { 'none' })  root=$Root"
Say "  log=$LogFile"
Step 2 'Reading the answer file'

try {
    $answer = Read-AnswerFile $Config
    Test-AnswerFile $answer
} catch {
    Say "  FAIL  answer file: $($_.Exception.Message)"
    $script:Errors++
    if (-not $ValidateOnly) { Write-Result }
    exit 2
}
Ok "answer file is valid (device $(Get-Ini $answer 'wolf' 'device_name'), hub $(Get-Ini $answer 'wolf' 'hub_url'))"
if ($ValidateOnly) { exit 0 }

$hubUrl = Get-Ini $answer 'wolf' 'hub_url'
$hubWait = 30

try { Save-StateBeforeInstall $answer }
catch {
    Fail "could not save the backup, so nothing was changed: $($_.Exception.Message)"
    Write-Result
    exit 1
}

try {
    if ($Prereqs) { Invoke-Prereqs $answer } else { Skip 'Git + Python (not selected)' }
    if ($Shares) { Invoke-Shares $answer } else { Skip 'network shares (not selected)' }
    Invoke-GitIdentity
    if ($Client) { Invoke-Client $answer } else { Skip 'Cursor / Claude Code client (not selected)' }
    if ($Obsidian) { Invoke-Obsidian $answer } else { Skip 'Obsidian (not selected)' }

    if ($Mode -eq 'new') {
        if (Invoke-NewHub $answer) { $hubWait = 600 }
    } elseif ($Mode -eq 'update') {
        if (Invoke-UpdateHub) { $hubWait = 600 }
    }

    Step 95 'Checking the hub'
    Test-Health $hubUrl $hubWait
} catch {
    Fail "unexpected error: $($_.Exception.Message)"
}

Write-Result
Step 100 $(if ($script:Errors -eq 0) { 'Done' } else { "Finished with $($script:Errors) problem(s)" })
Say "Summary: $($script:Errors) error(s), $($script:Warnings) warning(s), hub health: $($script:Health). Log: $LogFile"
if ($script:Errors -eq 0) { exit 0 } else { exit 1 }
