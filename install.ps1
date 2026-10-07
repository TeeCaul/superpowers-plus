<#
.SYNOPSIS
    Installs superpowers-plus on Windows (no WSL) via Git Bash; runs install.sh on macOS and Linux.

.DESCRIPTION
    On Windows the default run is a full install:

      1. Installs missing prerequisites with winget: Git for Windows
         (Git.Git, provides Git Bash), Node.js LTS (OpenJS.NodeJS.LTS),
         Python 3 (Python.Python.3.12), and jq (jqlang.jq).
      2. Writes python3 and python3.cmd shims to ~/.local/bin (Python on
         Windows ships python.exe only) and prepends ~/.local/bin to the
         user PATH.
      3. Sets user environment variables CLAUDE_CODE_GIT_BASH_PATH (Git
         Bash location, read by Claude Code) and PYTHONUTF8=1.
      4. Runs install.sh under Git Bash, which installs skills, Claude Code
         hooks, git gates, tools, rules, and templates as on macOS/Linux.

    With -SkillsOnly, no prerequisites are needed and only skills are
    deployed, with PowerShell, following install_skills() in
    lib/install/deploy.sh:

      ~/.codex/skills    Augment Agent (superpowers-augment.js)
      ~/.claude/skills   Claude Code
      ~/.agents/skills   Augment IDE slash menu and Codex (skills with
                         augment_menu: true, manifest renamed to SKILL.md)

    Each skill is deployed under its first /sp* trigger (for example sp-debug),
    or under its folder name when it declares none. skills/_shared/ is copied
    to ~/.codex/skills and ~/.claude/skills. The Augment adapter
    (superpowers-augment.js and lib/) is copied to ~/.codex/superpowers-augment.
    Deployed names are recorded in
    ~/.codex/superpowers-plus/install-state/skills.manifest, the manifest
    install.sh and uninstall.sh use, so a skill removed from the repo is pruned
    on the next run.

    -SkillsOnly skips Claude Code lifecycle hooks, git commit and push gates,
    tools, rules, templates, and Claude Desktop ZIPs.

    On macOS and Linux this script runs bash install.sh with the matching flags.

    Exit codes: 0 success, 1 error (message on stderr).

.PARAMETER Categories
    Comma-separated top-level skills/ folders to install, for example
    engineering,writing. Default: all categories.

.PARAMETER SkipAugment
    Deploy to ~/.claude/skills only. Skips ~/.codex/skills, ~/.agents/skills,
    and the Augment adapter.

.PARAMETER Force
    Install even if ~/.codex/.superpowers-ecosystem names a different
    superpowers ecosystem. The existing deployment is overwritten. Without
    -SkillsOnly this is passed to install.sh as --force, which also runs
    git reset --hard origin/main and git clean -fd in
    ~/.codex/superpowers-plus when that checkout is ahead of or has diverged
    from origin/main.

.PARAMETER Uninstall
    Run uninstall.sh under Git Bash and remove the python3 shims. Installs
    nothing; Git Bash must already be present. The ~/.local/bin PATH entry,
    CLAUDE_CODE_GIT_BASH_PATH, PYTHONUTF8, and winget packages are left in
    place. With -SkillsOnly, remove the skills listed in the manifest,
    _shared/, and the ~/.agents/skills entries tagged source: superpowers-plus.

.PARAMETER SkillsOnly
    Windows only. Deploy skills with PowerShell; do not use Git Bash or
    install prerequisites.

.PARAMETER NoPrereqInstall
    Windows only. Do not run winget; fail if a prerequisite is missing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkillsOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Categories engineering,writing

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string[]]$Categories = @(),
    [switch]$SkipAugment,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$SkillsOnly,
    [switch]$NoPrereqInstall
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSStyle -ErrorAction SilentlyContinue) { $PSStyle.OutputRendering = 'PlainText' }

# -Categories a,b binds as an array from a PowerShell prompt and as "a,b" via -File.
$CategoryList = (@($Categories) -join ',')
$Ecosystem = 'superpowers-plus'
$RepoRoot = $PSScriptRoot
$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

# --- macOS / Linux: delegate to install.sh ---------------------------------

if (-not $OnWindows) {
    $bashArgs = New-Object System.Collections.Generic.List[string]
    $bashArgs.Add((Join-Path $RepoRoot 'install.sh'))
    if ($Uninstall) { $bashArgs.Add('--uninstall') }
    if ($Force) { $bashArgs.Add('--force') }
    if ($SkipAugment) { $bashArgs.Add('--skip-augment') }
    if ($CategoryList) { $bashArgs.Add('--categories'); $bashArgs.Add($CategoryList) }
    & bash @bashArgs
    exit $LASTEXITCODE
}

# --- Windows: Git Bash bootstrap -------------------------------------------

function Stop-Bootstrap([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

# Append machine and user PATH entries from the registry that this session
# lacks, keeping the session's own entries and order.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $current = @($env:Path.Split(';') | Where-Object { $_ })
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($p in $current + @("$machine;$user".Split(';'))) {
        if (-not $p) { continue }
        if (-not ($merged | Where-Object { $_.TrimEnd('\') -ieq $p.TrimEnd('\') })) { $merged.Add($p) }
    }
    $env:Path = $merged -join ';'
}

function Install-WingetPackage([string]$Id) {
    if ($NoPrereqInstall) { Stop-Bootstrap "$Id is missing and -NoPrereqInstall was given. Install it: winget install --id $Id -e" }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Stop-Bootstrap "$Id is missing and winget is not available. Install it manually, or re-run with -SkillsOnly."
    }
    Write-Host "Installing $Id with winget..."
    & winget.exe install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { Stop-Bootstrap "winget install --id $Id failed (exit $LASTEXITCODE)" }
    Update-SessionPath
}

function Find-GitBash {
    $roots = New-Object System.Collections.Generic.List[string]
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        # <root>\cmd\git.exe, <root>\bin\git.exe or <root>\mingw64\bin\git.exe
        $d = Split-Path -Parent $git.Source
        $roots.Add((Split-Path -Parent $d))
        $roots.Add((Split-Path -Parent (Split-Path -Parent $d)))
    }
    foreach ($key in @('HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows')) {
        $p = Get-ItemProperty -Path $key -Name InstallPath -ErrorAction SilentlyContinue
        if ($p) { $roots.Add($p.InstallPath) }
    }
    if ($env:ProgramFiles) { $roots.Add((Join-Path $env:ProgramFiles 'Git')) }
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git')) }
    foreach ($r in $roots) {
        if (-not $r) { continue }
        $bash = Join-Path $r 'bin\bash.exe'
        if (Test-Path -LiteralPath $bash -PathType Leaf) { return $bash }
    }
    return $null
}

# Real python.exe, skipping the Microsoft Store stubs in WindowsApps.
function Find-Python {
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        # PowerShell 5.1 turns redirected native stderr into a terminating
        # error under ErrorActionPreference=Stop (py prints one when no
        # Python 3 runtime is installed).
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $exe = (& py.exe -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
            $rc = $LASTEXITCODE
        } catch { $exe = $null; $rc = 1 } finally { $ErrorActionPreference = $prev }
        if ($rc -eq 0 -and $exe -and (Test-Path -LiteralPath "$exe".Trim() -PathType Leaf)) { return "$exe".Trim() }
    }
    foreach ($c in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($c.Source -notmatch '\\WindowsApps\\') { return $c.Source }
    }
    if ($env:LOCALAPPDATA) {
        $found = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe') -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# C:\Users\me\x -> /c/Users/me/x
function ConvertTo-MsysPath([string]$Path) {
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    }
    return ($Path -replace '\\', '/')
}

# Reads and writes HKCU\Environment\Path directly so %VAR% entries stay
# unexpanded and the value keeps its REG_EXPAND_SZ type.
function Add-UserPathFront([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $user = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($user.Split(';') | Where-Object { $_ })
        if ($parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $Dir.TrimEnd('\') }) { return }
        $key.SetValue('Path', ((@($Dir) + $parts) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    # Broadcast WM_SETTINGCHANGE so new processes see the change.
    [Environment]::SetEnvironmentVariable('SUPERPOWERS_PLUS_PATH_REFRESH', [Guid]::NewGuid().ToString(), 'User')
    [Environment]::SetEnvironmentVariable('SUPERPOWERS_PLUS_PATH_REFRESH', $null, 'User')
    Write-Host "Added $Dir to the front of the user PATH"
}

function Set-UserEnv([string]$Name, [string]$Value) {
    if ([Environment]::GetEnvironmentVariable($Name, 'User') -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Write-Host "Set user environment variable $Name=$Value"
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

$ShimMarker = 'superpowers-plus python3 shim'

# python3 for Git Bash, python3.cmd for PowerShell and CMD (PATHEXT).
function Install-Python3Shim([string]$PythonExe, [string]$BinDir) {
    $shims = @{
        'python3'     = "#!/usr/bin/env bash`n# $ShimMarker`nexec `"$(ConvertTo-MsysPath $PythonExe)`" `"`$@`"`n"
        'python3.cmd' = "@rem $ShimMarker`r`n@`"$PythonExe`" %*`r`n"
    }
    [void][IO.Directory]::CreateDirectory($BinDir)
    foreach ($name in $shims.Keys) {
        $shim = Join-Path $BinDir $name
        if ((Test-Path -LiteralPath $shim -PathType Leaf) -and -not (Select-String -LiteralPath $shim -SimpleMatch $ShimMarker -Quiet)) {
            Write-Warning "$shim exists and was not written by superpowers-plus; leaving it"
            continue
        }
        [IO.File]::WriteAllText($shim, $shims[$name], (New-Object System.Text.UTF8Encoding $false))
    }
}

function Remove-Python3Shim([string]$BinDir) {
    foreach ($name in @('python3', 'python3.cmd')) {
        $shim = Join-Path $BinDir $name
        if ((Test-Path -LiteralPath $shim -PathType Leaf) -and (Select-String -LiteralPath $shim -SimpleMatch $ShimMarker -Quiet)) {
            Remove-Item -LiteralPath $shim -Force
            Write-Host "Removed $shim"
        }
    }
}

if (-not $SkillsOnly) {
    Update-SessionPath
    $binDir = Join-Path $HOME '.local\bin'
    $bashArgs = New-Object System.Collections.Generic.List[string]
    if ($Uninstall) {
        $gitBash = Find-GitBash
        if (-not $gitBash) { Stop-Bootstrap 'Git Bash (bash.exe) not found. Install Git for Windows, or re-run with -SkillsOnly -Uninstall.' }
        $bashArgs.Add((ConvertTo-MsysPath (Join-Path $RepoRoot 'uninstall.sh')))
        $bashArgs.Add('--yes')
    } else {
        if (-not (Find-GitBash)) { Install-WingetPackage 'Git.Git' }
        $gitBash = Find-GitBash
        if (-not $gitBash) { Stop-Bootstrap 'Git Bash (bash.exe) not found after installing Git for Windows. Re-run with -SkillsOnly to deploy skills without it.' }
        if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { Install-WingetPackage 'OpenJS.NodeJS.LTS' }
        if (-not (Find-Python)) { Install-WingetPackage 'Python.Python.3.12' }
        $python = Find-Python
        if (-not $python) { Stop-Bootstrap 'python.exe not found after installing Python 3.' }
        if (-not (Get-Command jq.exe -ErrorAction SilentlyContinue)) { Install-WingetPackage 'jqlang.jq' }

        Install-Python3Shim $python $binDir
        Add-UserPathFront $binDir
        Set-UserEnv 'CLAUDE_CODE_GIT_BASH_PATH' $gitBash
        Set-UserEnv 'PYTHONUTF8' '1'
        Update-SessionPath

        $bashArgs.Add((ConvertTo-MsysPath (Join-Path $RepoRoot 'install.sh')))
        $bashArgs.Add('--yes')
        if ($Force) { $bashArgs.Add('--force') }
        if ($SkipAugment) { $bashArgs.Add('--skip-augment') }
        if ($CategoryList) { $bashArgs.Add('--categories'); $bashArgs.Add($CategoryList) }
        if ($VerbosePreference -eq 'Continue') { $bashArgs.Add('--verbose') }
    }
    # Git Bash derives HOME from HOMEDRIVE/HOMEPATH, which can point at a
    # network share; the AI tools read skills from USERPROFILE.
    if (-not $env:HOME) { $env:HOME = $env:USERPROFILE }
    Write-Host "Running under Git Bash ($gitBash): $($bashArgs -join ' ')"
    & $gitBash @bashArgs
    $rc = $LASTEXITCODE
    if ($rc -eq 0 -and $Uninstall) { Remove-Python3Shim $binDir }
    if ($rc -eq 0 -and -not $Uninstall) { Write-Host 'Open a new terminal so PATH and environment changes take effect, then restart your AI tool.' }
    exit $rc
}

# --- Windows: native deploy (-SkillsOnly) ----------------------------------

$CodexDir = Join-Path $HOME '.codex'
$SkillsDir = Join-Path $CodexDir 'skills'
$ClaudeSkillsDir = Join-Path (Join-Path $HOME '.claude') 'skills'
$AugmentMenuDir = Join-Path (Join-Path $HOME '.agents') 'skills'
$AdapterDir = Join-Path $CodexDir 'superpowers-augment'
$StateDir = Join-Path (Join-Path $CodexDir 'superpowers-plus') 'install-state'
$Manifest = Join-Path $StateDir 'skills.manifest'
$EcosystemLock = Join-Path $CodexDir '.superpowers-ecosystem'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

$SkillTargets = @($ClaudeSkillsDir)
if (-not $SkipAugment) { $SkillTargets = @($SkillsDir, $ClaudeSkillsDir) }

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Warn([string]$Message) { Write-Warning $Message }
function Stop-Install([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

function Test-SkillName([string]$Name) {
    return $Name -cmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$'
}

function Test-ReparsePoint($Item) {
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# SKILL.md wins over skill.md, matching deploy.sh.
function Get-SkillFile([string]$Dir) {
    foreach ($name in @('SKILL.md', 'skill.md')) {
        $path = Join-Path $Dir $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $leaf = (Get-Item -LiteralPath $path -Force).Name
            return (Join-Path $Dir $leaf)
        }
    }
    return $null
}

# First /sp* trigger, using the same three patterns as _extract_sp_trigger().
function Get-SpTrigger([string]$File) {
    $lines = [IO.File]::ReadAllLines($File)
    foreach ($line in $lines) {
        if ($line -notmatch '^triggers:') { continue }
        if ($line -match '"(/sp[^"]*)"') { return $Matches[1] }
        if ($line -match "'(/sp[^']*)'") { return $Matches[1] }
        break
    }
    foreach ($line in $lines) {
        if ($line -match '^ *- (/sp.*)$') { return $Matches[1] }
    }
    return ''
}

function Get-DestName([string]$SkillDir) {
    $file = Get-SkillFile $SkillDir
    if ($file) {
        $t = Get-SpTrigger $file
        if ($t) { return $t.Substring(1) }
    }
    return (Split-Path -Leaf $SkillDir)
}

# Remove a file, directory tree, or link without following a link.
function Remove-Entry([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (Test-ReparsePoint $item) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
    } elseif ($item.PSIsContainer) {
        [IO.Directory]::Delete($Path, $true)
    } else {
        [IO.File]::Delete($Path)
    }
}

# Recursive copy that skips links so a skill cannot pull in outside files.
function Copy-Tree([string]$Source, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($entry in (Get-ChildItem -LiteralPath $Source -Force)) {
        if (Test-ReparsePoint $entry) { continue }
        $to = Join-Path $Destination $entry.Name
        if ($entry.PSIsContainer) { Copy-Tree $entry.FullName $to }
        else { [IO.File]::Copy($entry.FullName, $to, $true) }
    }
}

function Write-TextFile([string]$Path, [string]$Content) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $tmp = "$Path.tmp.$PID"
    [IO.File]::WriteAllText($tmp, $Content, $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-SourceTag([string]$Dir) {
    $file = Get-SkillFile $Dir
    if ($null -eq $file) { return $false }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -cmatch "^source: $Ecosystem\s*$") { return $true }
    }
    return $false
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $null }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($Manifest)) {
        $n = $line.Trim()
        if (-not $n) { continue }
        if (-not (Test-SkillName $n)) { Write-Warn "skipping unsafe manifest entry '$n'"; continue }
        $names.Add($n)
    }
    return , $names.ToArray()
}

function Assert-Ecosystem {
    if (-not (Test-Path -LiteralPath $EcosystemLock -PathType Leaf)) { return }
    $installed = ([IO.File]::ReadAllLines($EcosystemLock) | Select-Object -First 1)
    if ($null -eq $installed) { return }
    $installed = $installed.Trim()
    if ($installed -eq '' -or $installed -eq $Ecosystem) { return }
    if ($Force) {
        Write-Warn "foreign superpowers ecosystem '$installed' found in $EcosystemLock; -Force given, overwriting"
        return
    }
    Stop-Install "a different superpowers ecosystem ('$installed') is already deployed at $EcosystemLock. Remove it before installing $Ecosystem, or re-run with -Force."
}

# --- Skill discovery -------------------------------------------------------

# Skill source dirs as objects with Dir and Name (deploy name). Mirrors the
# walk in install_skills(): skills/<skill>/ or skills/<domain>/<skill>/,
# skipping names that start with '_', filtered by -Categories.
function Get-SourceSkills([string[]]$Selected) {
    $result = New-Object System.Collections.Generic.List[object]
    $root = Join-Path $RepoRoot 'skills'
    foreach ($top in (Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name)) {
        if ($top.Name.StartsWith('_')) { continue }
        if ($Selected.Count -gt 0 -and $Selected -notcontains $top.Name) { continue }
        if ($null -ne (Get-SkillFile $top.FullName)) {
            $result.Add([pscustomobject]@{ Dir = $top.FullName; Name = (Get-DestName $top.FullName) })
            continue
        }
        foreach ($sub in (Get-ChildItem -LiteralPath $top.FullName -Directory -Force | Sort-Object Name)) {
            if ($sub.Name.StartsWith('_')) { continue }
            if ($null -eq (Get-SkillFile $sub.FullName)) { continue }
            $result.Add([pscustomobject]@{ Dir = $sub.FullName; Name = (Get-DestName $sub.FullName) })
        }
    }
    return , $result.ToArray()
}

function Get-SelectedCategories {
    if (-not $CategoryList -or $CategoryList -eq 'all') { return , @() }
    $root = Join-Path $RepoRoot 'skills'
    $available = @(Get-ChildItem -LiteralPath $root -Directory -Force |
        Where-Object { -not $_.Name.StartsWith('_') } | ForEach-Object { $_.Name })
    $selected = @($CategoryList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($c in $selected) {
        if ($available -notcontains $c) {
            Stop-Install "unknown category '$c'. Available: $($available -join ', ')"
        }
    }
    return , $selected
}

# --- Deploy ----------------------------------------------------------------

function Install-Skill($Skill, $Errors) {
    if (-not (Test-SkillName $Skill.Name)) {
        Write-Warn "skipping '$($Skill.Dir)': unsafe deploy name '$($Skill.Name)'"
        return $false
    }
    foreach ($target in $SkillTargets) {
        $dest = Join-Path $target $Skill.Name
        try {
            [void][IO.Directory]::CreateDirectory($target)
            Remove-Entry $dest
            Copy-Tree $Skill.Dir $dest
        } catch {
            $Errors.Add("$($Skill.Name): deploy -> ${dest}: $($_.Exception.Message)")
            return $false
        }
    }
    return $true
}

# Remove names from the previous manifest that this run did not deploy.
# Without a manifest, fall back to folders tagged source: superpowers-plus.
function Remove-StaleSkills([string[]]$Current, $Previous) {
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Current) { [void]$keep.Add($n) }
    foreach ($target in $SkillTargets) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { continue }
        $candidates = @()
        if ($null -ne $Previous) { $candidates = $Previous }
        else {
            $candidates = @(Get-ChildItem -LiteralPath $target -Directory -Force |
                Where-Object { -not $_.Name.StartsWith('_') -and (Test-SourceTag $_.FullName) } |
                ForEach-Object { $_.Name })
        }
        foreach ($name in $candidates) {
            if ($keep.Contains($name)) { continue }
            $dest = Join-Path $target $name
            if ($null -eq (Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) { continue }
            try { Remove-Entry $dest; Write-Verbose "removed stale skill $dest" } catch {
                Write-Warn "could not remove stale skill ${dest}: $($_.Exception.Message)"
            }
        }
    }
}

function Install-Shared([System.Collections.Generic.List[string]]$Errors) {
    $src = Join-Path (Join-Path $RepoRoot 'skills') '_shared'
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { return }
    foreach ($target in $SkillTargets) {
        $dest = Join-Path $target '_shared'
        try {
            Remove-Entry $dest
            Copy-Tree $src $dest
        } catch {
            $Errors.Add("failed to deploy _shared/ to ${dest}: $($_.Exception.Message)")
            Write-Warn "failed to deploy _shared/ to ${dest}: $($_.Exception.Message)"
        }
    }
}

# Copy augment_menu: true skills from ~/.codex/skills to ~/.agents/skills as
# SKILL.md. Prunes this ecosystem's stale entries only.
function Export-AugmentMenu([object[]]$Deployed) {
    [void][IO.Directory]::CreateDirectory($AugmentMenuDir)
    $exported = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Deployed) {
        $installed = Join-Path $SkillsDir $s.Name
        $file = Get-SkillFile $installed
        if ($null -eq $file) { continue }
        if (-not ([IO.File]::ReadAllLines($file) | Where-Object { $_ -match '^augment_menu: *true' })) { continue }
        $dest = Join-Path $AugmentMenuDir $s.Name
        try {
            Remove-Entry $dest
            Copy-Tree $installed $dest
            $lower = Join-Path $dest 'skill.md'
            if ((Test-Path -LiteralPath $lower -PathType Leaf) -and (Get-Item -LiteralPath $lower -Force).Name -ceq 'skill.md') {
                # Two-step rename so the case change sticks on case-insensitive NTFS.
                $tmp = Join-Path $dest '_skill_tmp.md'
                [IO.File]::Move($lower, $tmp)
                [IO.File]::Move($tmp, (Join-Path $dest 'SKILL.md'))
            }
            [void]$exported.Add($s.Name)
        } catch {
            Write-Warn "failed to export $($s.Name) to ${dest}: $($_.Exception.Message)"
        }
    }
    foreach ($dir in (Get-ChildItem -LiteralPath $AugmentMenuDir -Directory -Force)) {
        if ($exported.Contains($dir.Name) -or -not (Test-SourceTag $dir.FullName)) { continue }
        try { Remove-Entry $dir.FullName } catch {
            Write-Warn "could not remove stale slash menu skill $($dir.FullName): $($_.Exception.Message)"
        }
    }
    Write-Info "Exported $($exported.Count) skill(s) to Augment slash menu ($AugmentMenuDir)"
}

function Install-Adapter {
    $src = Join-Path $RepoRoot 'superpowers-augment.js'
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Warn "adapter source not found: $src"
        return
    }
    [void][IO.Directory]::CreateDirectory($AdapterDir)
    [IO.File]::Copy($src, (Join-Path $AdapterDir 'superpowers-augment.js'), $true)
    $libSrc = Join-Path $RepoRoot 'lib'
    if (Test-Path -LiteralPath $libSrc -PathType Container) {
        $libDest = Join-Path $AdapterDir 'lib'
        Remove-Entry $libDest
        Copy-Tree $libSrc $libDest
    }
    Write-Info "Adapter installed: $AdapterDir"
}

# --- Uninstall -------------------------------------------------------------

function Invoke-Uninstall {
    $names = Read-Manifest
    if ($null -eq $names) {
        Write-Warn "no manifest at $Manifest; removing skills tagged source: $Ecosystem"
        $names = @()
    }
    $removed = 0
    foreach ($target in @($SkillsDir, $ClaudeSkillsDir)) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { continue }
        $candidates = @($names)
        $candidates += @(Get-ChildItem -LiteralPath $target -Directory -Force |
            Where-Object { -not $_.Name.StartsWith('_') -and (Test-SourceTag $_.FullName) } |
            ForEach-Object { $_.Name })
        foreach ($name in ($candidates | Sort-Object -Unique)) {
            $dest = Join-Path $target $name
            if ($null -eq (Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) { continue }
            Remove-Entry $dest
            $removed++
        }
        Remove-Entry (Join-Path $target '_shared')
    }
    if (Test-Path -LiteralPath $AugmentMenuDir -PathType Container) {
        foreach ($dir in (Get-ChildItem -LiteralPath $AugmentMenuDir -Directory -Force)) {
            if (Test-SourceTag $dir.FullName) { Remove-Entry $dir.FullName; $removed++ }
        }
    }
    Remove-Entry $AdapterDir
    Remove-Entry $Manifest
    if (Test-Path -LiteralPath $EcosystemLock -PathType Leaf) {
        $owner = ([IO.File]::ReadAllLines($EcosystemLock) | Select-Object -First 1)
        if ($null -ne $owner -and $owner.Trim() -eq $Ecosystem) { Remove-Entry $EcosystemLock }
    }
    Write-Info "Removed $removed skill folder(s), _shared/, and the Augment adapter."
}

# --- Main ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills') -PathType Container)) {
    Stop-Install "skills/ not found next to install.ps1 ($RepoRoot)"
}

if ($Uninstall) {
    try { Invoke-Uninstall } catch { Stop-Install $_.Exception.Message }
    exit 0
}

Assert-Ecosystem
$selected = Get-SelectedCategories
$skills = Get-SourceSkills $selected
$previous = Read-Manifest

$errors = New-Object System.Collections.Generic.List[string]
$deployed = New-Object System.Collections.Generic.List[object]
foreach ($s in $skills) {
    if (Install-Skill $s $errors) { $deployed.Add($s) }
}
foreach ($e in $errors) { Write-Warn $e }

if ($deployed.Count -eq 0) {
    Stop-Install 'no skills were installed; skipping prune to prevent mass deletion'
}

$currentNames = @($deployed | ForEach-Object { $_.Name } | Sort-Object -Unique -CaseSensitive)
Remove-StaleSkills $currentNames $previous
Install-Shared $errors
Write-TextFile $Manifest (($currentNames -join "`n") + "`n")

if (-not $SkipAugment) {
    Export-AugmentMenu $deployed.ToArray()
    Install-Adapter
}

Write-TextFile $EcosystemLock "$Ecosystem`n"

Write-Info ''
Write-Info "Installed $($deployed.Count) skill(s) to:"
foreach ($t in $SkillTargets) { Write-Info "  $t" }
Write-Info ''
Write-Info 'Not installed with -SkillsOnly (run install.ps1 without it for these):'
Write-Info '  Claude Code lifecycle hooks, git commit and push gates, tools, rules, templates, Claude Desktop ZIPs.'
Write-Info 'Restart your AI tool to pick up the new skills.'
if ($errors.Count -gt 0) { exit 1 }
exit 0
