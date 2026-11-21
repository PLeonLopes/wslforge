#Requires -Version 5.1
<#
wslforge for Windows: a few questions (every one has a default), then it
enables WSL if needed, creates the distro and your Linux user, and runs
install.sh inside it. One command, from a PC without WSL to a ready terminal.

Run it:
  irm https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.ps1 | iex

With options:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.ps1))) -Yes

This file must stay plain ASCII: Windows PowerShell 5.1 misreads other
characters in files without a BOM. Symbols are built with [char] instead.
#>
param(
    # Accept every default without asking (the Linux password is still asked).
    [switch]$Yes,
    # Menu style: auto (gum when possible), gum or text.
    [ValidateSet('auto', 'gum', 'text')]
    [string]$Ui = 'auto',
    # Where the answers are saved (default: ~\.wslforge\wslforge.conf).
    [Alias('OutFile')]
    [string]$Config = '',
    # Only save the answers; do not set anything up.
    [switch]$ConfigOnly,
    # Use the saved answers instead of asking again (also used after a restart).
    [switch]$Resume,
    # Branch or tag of wslforge to install inside the distro.
    [string]$Ref = '',
    # A local wslforge folder to install from instead of GitHub (development).
    [string]$RepoPath = '',
    [switch]$Help
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Functions read the parameters from here. Script parameters used only inside
# functions look unused to PSScriptAnalyzer (PSReviewUnusedParameter).
$RunOptions = @{
    Yes        = [bool]$Yes
    Ui         = $Ui
    Config     = $Config
    ConfigOnly = [bool]$ConfigOnly
    Resume     = [bool]$Resume
    Ref        = $Ref
    RepoPath   = $RepoPath
    Help       = [bool]$Help
}

$WslforgeVersion = '0.2.0-dev'
$GumVersion = '2.0.2'
$StateDir = Join-Path $HOME '.wslforge'
$DistroListUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
$RawUrl = 'https://raw.githubusercontent.com/PLeonLopes/wslforge'
# "wsl --install --name/--location" needs this WSL version or newer.
$MinWslVersion = [version]'2.4.4'
$WslConfigPath = Join-Path $HOME '.wslconfig'

# Families of Microsoft's distro list that install.sh supports (apt, dnf and
# pacman based).
$SupportedFamilies = @('Ubuntu', 'Debian', 'kali', 'Fedora', 'AlmaLinux', 'archlinux')
$FallbackDistros = @(
    [pscustomobject]@{ Name = 'Ubuntu'; FriendlyName = 'Ubuntu' }
    [pscustomobject]@{ Name = 'Ubuntu-24.04'; FriendlyName = 'Ubuntu 24.04 LTS' }
    [pscustomobject]@{ Name = 'Debian'; FriendlyName = 'Debian GNU/Linux' }
    [pscustomobject]@{ Name = 'kali-linux'; FriendlyName = 'Kali Linux Rolling' }
    [pscustomobject]@{ Name = 'archlinux'; FriendlyName = 'Arch Linux' }
)

# ---------------------------------------------------------------- Forge palette
# wslforge's visual identity (same values as lib/common.sh). Hex for gum,
# 256-color ANSI codes for plain output.
$Forge = @{
    Ember    = '#FF8A3D'   # accent: cursor, selection, borders
    Amber    = '#FFC857'   # headings and step titles
    Ash      = '#8A817A'   # secondary text
    Text     = '#E8E2DA'   # text on dark backgrounds
    Moss     = '#9CCC65'   # success
    Charcoal = '#1A1410'   # text on ember buttons
    Iron     = '#2B2622'   # inactive buttons
}

$UseColor = (-not $env:NO_COLOR) -and (-not [Console]::IsOutputRedirected)
function Get-Ansi([string]$Code) {
    if ($UseColor) { return "$([char]27)[$($Code)m" }
    return ''
}
$C = @{
    Reset = Get-Ansi '0'
    Bold  = Get-Ansi '1'
    Ember = Get-Ansi '38;5;209'
    Amber = Get-Ansi '38;5;221'
    Ash   = Get-Ansi '38;5;245'
    Moss  = Get-Ansi '38;5;149'
    Red   = Get-Ansi '38;5;203'
}
$Sym = @{
    Ok  = [string][char]0x2714   # heavy check mark
    Dot = [string][char]0x00B7   # middle dot
}

# ---------------------------------------------------------------- output

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "$($C.Bold)$($C.Amber)==> $Text$($C.Reset)"
}

function Write-Note([string]$Text) {
    Write-Host "    $Text"
}

function Write-Success([string]$Text) {
    Write-Host "    $($C.Moss)$($Sym.Ok)$($C.Reset) $Text"
}

function Write-Caution([string]$Text) {
    Write-Host "    $($C.Ember)!$($C.Reset) $Text"
}

function Show-Usage {
    Write-Host @"
wslforge $WslforgeVersion for Windows: set up WSL for development.

Usage:
  irm https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.ps1 | iex
  .\install.ps1 [-Yes] [-Ui auto|gum|text] [-Config PATH] [-ConfigOnly] [-Resume]

Options:
  -Yes          Accept every default (the Linux password is still asked)
  -Ui NAME      Menu style: auto (default), gum or text
  -Config PATH  Where the answers are saved (default: ~\.wslforge\wslforge.conf)
  -ConfigOnly   Only save the answers; set nothing up
  -Resume       Use the saved answers instead of asking again
  -Ref REF      Branch or tag of wslforge to install in the distro
  -RepoPath DIR Install from a local wslforge folder (development)
  -Help         Show this help

What it does: asks a few questions, enables WSL (administrator rights and a
restart, only if it is not enabled yet; it continues by itself after the
restart), creates the distro and your Linux user, sets the WSL memory and CPU
limits in ~\.wslconfig, and installs your tools inside the distro.
"@
}

# ---------------------------------------------------------------- gum

# Mutable UI state lives in a hashtable instead of $script: variables:
# "& ([scriptblock]::Create(...))" runs this file in a scope where $script:
# points at the caller, not here.
$UiState = @{ Backend = 'text'; Gum = '' }

# Get-Gum: the pinned gum release in ~\.wslforge\bin, downloaded on first use
# and checked against the release checksums. $null when unavailable.
function Get-Gum {
    $bin = Join-Path $StateDir 'bin\gum.exe'
    if (Test-Path $bin) { return $bin }

    $arch = 'i386'
    if ([Environment]::Is64BitOperatingSystem) { $arch = 'x86_64' }
    $name = "gum_$($GumVersion)_Windows_$arch.zip"
    $url = "https://github.com/charmbracelet/gum/releases/download/v$GumVersion"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wslforge-' + [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Write-Note "Downloading gum $GumVersion for the interactive menu..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp $name
        $sums = Join-Path $tmp 'checksums.txt'
        Invoke-WebRequest -UseBasicParsing -Uri "$url/$name" -OutFile $zip
        Invoke-WebRequest -UseBasicParsing -Uri "$url/checksums.txt" -OutFile $sums

        $line = Get-Content $sums | Where-Object { $_ -match (' ' + [regex]::Escape($name) + '$') } | Select-Object -First 1
        if (-not $line) { throw "No checksum for $name" }
        $expected = ($line -split '\s+')[0]
        $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash
        if ($actual -ne $expected) { throw "Checksum mismatch for $name" }

        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
        $exe = Get-ChildItem -Path (Join-Path $tmp 'x') -Recurse -Filter 'gum.exe' | Select-Object -First 1
        if (-not $exe) { throw 'gum.exe not found in the archive' }
        New-Item -ItemType Directory -Force -Path (Split-Path $bin) | Out-Null
        Copy-Item -Path $exe.FullName -Destination $bin
        return $bin
    }
    catch {
        Write-Note "Could not get gum ($($_.Exception.Message)); using a simpler interface."
        return $null
    }
    finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
}

# Use-ForgeTheme: paint gum with the Forge palette. Plain item text keeps the
# terminal's own color, so it stays readable on light backgrounds.
function Use-ForgeTheme {
    $env:GUM_CHOOSE_CURSOR_FOREGROUND = $Forge.Ember
    $env:GUM_CHOOSE_SELECTED_FOREGROUND = $Forge.Ember
    $env:GUM_CHOOSE_HEADER_FOREGROUND = $Forge.Amber
    $env:GUM_INPUT_HEADER_FOREGROUND = $Forge.Amber
    $env:GUM_INPUT_PROMPT_FOREGROUND = $Forge.Ember
    $env:GUM_INPUT_CURSOR_FOREGROUND = $Forge.Ember
    $env:GUM_INPUT_PLACEHOLDER_FOREGROUND = $Forge.Ash
    $env:GUM_CONFIRM_PROMPT_FOREGROUND = $Forge.Amber
    $env:GUM_CONFIRM_SELECTED_BACKGROUND = $Forge.Ember
    $env:GUM_CONFIRM_SELECTED_FOREGROUND = $Forge.Charcoal
    $env:GUM_CONFIRM_UNSELECTED_BACKGROUND = $Forge.Iron
    $env:GUM_CONFIRM_UNSELECTED_FOREGROUND = $Forge.Text
}

# Initialize-Ui: gum for a real console, plain prompts otherwise.
function Initialize-Ui {
    if ($RunOptions.Ui -eq 'text' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
    $gum = Get-Gum
    if ($gum) {
        $UiState.Gum = $gum
        $UiState.Backend = 'gum'
        Use-ForgeTheme
    }
}

# Invoke-Gum: run gum and return its exit code and answer. Ctrl+C cancels.
function Invoke-Gum([string[]]$GumArgs) {
    $answer = & $UiState.Gum @GumArgs
    $code = $LASTEXITCODE
    if ($code -eq 130) { throw 'Cancelled.' }
    return [pscustomobject]@{ Code = $code; Answer = ("$answer").Trim() }
}

# gum splits --selected on commas, so labels must not contain any.
function Format-Label([string]$Text) {
    return $Text.Replace(',', " $($Sym.Dot)")
}

# ---------------------------------------------------------------- prompts
# Each prompt works with gum or plain text and returns the answer.

function Show-Banner([string]$Title, [string]$Subtitle) {
    if ($UiState.Backend -eq 'gum') {
        $bold = & $UiState.Gum style --bold --foreground $Forge.Ember $Title
        & $UiState.Gum style --border rounded --border-foreground $Forge.Ember --padding '0 2' --margin '1 0 0 0' $bold $Subtitle | Out-Host
        return
    }
    Write-Host ''
    Write-Host "$($C.Bold)$($C.Ember)$Title$($C.Reset)"
    Write-Host $Subtitle
}

# Read-Choice TITLE DEFAULT OPTIONS: OPTIONS are objects with Key and Label.
function Read-Choice([string]$Title, [string]$Default, [object[]]$Options) {
    if ($UiState.Backend -eq 'gum') {
        $gumArgs = @('choose', '--header', $Title, '--label-delimiter', '|')
        $selected = $Options | Where-Object { $_.Key -eq $Default } | Select-Object -First 1
        if ($selected) { $gumArgs += @('--selected', (Format-Label $selected.Label)) }
        $gumArgs += @($Options | ForEach-Object { (Format-Label $_.Label) + '|' + $_.Key })
        $result = Invoke-Gum $gumArgs
        if ($result.Code -ne 0 -or -not $result.Answer) { throw 'Cancelled.' }
        return $result.Answer
    }

    Write-Host ''
    Write-Host "$($C.Amber)$Title$($C.Reset)"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ('  {0,2}) {1}' -f ($i + 1), $Options[$i].Label)
    }
    while ($true) {
        $reply = Read-Host "  Choose [default: $Default]"
        if ($null -eq $reply) { throw 'The input ended before every question was answered.' }
        if (-not $reply) { return $Default }
        $number = 0
        if ([int]::TryParse($reply, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) {
            return $Options[$number - 1].Key
        }
    }
}

# Read-Text PROMPT DEFAULT [VALIDATE]: VALIDATE returns an error message for a
# bad answer, or nothing when the answer is fine.
function Read-Text([string]$Prompt, [string]$Default, [scriptblock]$Validate = $null) {
    while ($true) {
        if ($UiState.Backend -eq 'gum') {
            $gumArgs = @('input', '--header', $Prompt, '--placeholder', $Prompt)
            # Windows PowerShell drops empty arguments, so --value only when set.
            if ($Default) { $gumArgs += @('--value', $Default) }
            $result = Invoke-Gum $gumArgs
            if ($result.Code -ne 0) { throw 'Cancelled.' }
            $value = $result.Answer
        }
        else {
            $hint = ''
            if ($Default) { $hint = " [$Default]" }
            $line = Read-Host "  $Prompt$hint"
            if ($null -eq $line) { throw 'The input ended before every question was answered.' }
            $value = $line.Trim()
        }
        if (-not $value) { $value = $Default }
        if ($Validate) {
            $problem = & $Validate $value
            if ($problem) {
                Write-Caution $problem
                continue
            }
        }
        return $value
    }
}

function Confirm-Answer([string]$Question) {
    if ($UiState.Backend -eq 'gum') {
        & $UiState.Gum confirm '--default=true' $Question
        if ($LASTEXITCODE -eq 130) { throw 'Cancelled.' }
        return ($LASTEXITCODE -eq 0)
    }
    $reply = Read-Host "$Question [Y/n]"
    return (-not $reply -or $reply -match '^[Yy]')
}

# Read-Password USER: ask for the new Linux password twice. Never stored.
function Read-Password([string]$User) {
    $prompt = "Password for $User in Linux (used by sudo)"
    while ($true) {
        $first = Read-Secret $prompt
        if ($first.Length -eq 0) {
            Write-Caution 'The password cannot be empty.'
            continue
        }
        $second = Read-Secret 'Type it again'
        if ((ConvertFrom-Secret $first) -cne (ConvertFrom-Secret $second)) {
            Write-Caution 'The passwords do not match; try again.'
            continue
        }
        return $first
    }
}

# Read-Secret PROMPT: a hidden answer, as a SecureString.
function Read-Secret([string]$Prompt) {
    if ($UiState.Backend -eq 'gum') {
        $result = Invoke-Gum @('input', '--password', '--header', $Prompt, '--placeholder', $Prompt)
        if ($result.Code -ne 0) { throw 'Cancelled.' }
        return (ConvertTo-Secret $result.Answer)
    }
    if ([Console]::IsInputRedirected) {
        # Piped input (automation): Read-Host -AsSecureString would wait for
        # a keyboard that is not there.
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'No password given.' }
        return (ConvertTo-Secret $line)
    }
    return (Read-Host -AsSecureString "  $Prompt")
}

function ConvertTo-Secret([string]$Text) {
    $secure = New-Object Security.SecureString
    foreach ($char in $Text.ToCharArray()) { $secure.AppendChar($char) }
    return $secure
}

function ConvertFrom-Secret([Security.SecureString]$Secret) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

# ---------------------------------------------------------------- system facts

# Get-DistroCatalog: installable distros of the supported families, from the
# same list "wsl --list --online" uses. A built-in list when offline.
function Get-DistroCatalog {
    try {
        $data = Invoke-RestMethod -UseBasicParsing -Uri $DistroListUrl -TimeoutSec 15
        if ($data -is [string]) { $data = $data | ConvertFrom-Json }
        $catalog = @()
        foreach ($family in $SupportedFamilies) {
            $entry = $data.ModernDistributions.PSObject.Properties[$family]
            if (-not $entry) { continue }
            foreach ($distro in $entry.Value) {
                $catalog += [pscustomobject]@{ Name = $distro.Name; FriendlyName = $distro.FriendlyName }
            }
        }
        if ($catalog.Count -gt 0) { return $catalog }
    }
    catch {
        Write-Note 'Could not download the list of distros; showing the built-in list.'
    }
    return $FallbackDistros
}

# Get-InstalledDistro: names of the distros already on this PC.
function Get-InstalledDistro {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $ErrorActionPreference = 'Continue'
    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'   # plain UTF-8 instead of UTF-16 output
    try {
        $output = & wsl.exe --list --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
    }
    finally {
        $env:WSL_UTF8 = $previous
    }
    return @($output | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
}

# Test-WslReady: true when WSL is already enabled on this PC.
function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    $ErrorActionPreference = 'Continue'
    & wsl.exe --status *> $null
    return ($LASTEXITCODE -eq 0)
}

# Get-WslVersion: the installed WSL version, or $null for the old built-in
# WSL that has no "--version" (it needs "wsl --update").
function Get-WslVersion {
    $ErrorActionPreference = 'Continue'
    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        $output = & wsl.exe --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
    }
    finally {
        $env:WSL_UTF8 = $previous
    }
    # The first line is localized ("WSL version: 2.4.11.0"); take the number.
    $first = "$($output | Select-Object -First 1)" -replace "`0", ''
    if ($first -match '(\d+\.\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    return $null
}

# Get-WslConfigNumber KEY: memory (in GB) or processors from ~\.wslconfig,
# so the questions start from what is already set. 0 when not set.
function Get-WslConfigNumber([string]$Key) {
    if (-not (Test-Path $WslConfigPath)) { return 0 }
    $value = Get-IniValue ([IO.File]::ReadAllLines($WslConfigPath)) 'wsl2' $Key
    if (-not $value) { return 0 }
    if ($Key -eq 'memory') {
        if ($value -match '^(\d+)\s*GB$') { return [int]$Matches[1] }
        if ($value -match '^(\d+)\s*MB$') { return [int][math]::Floor([int]$Matches[1] / 1024) }
        return 0
    }
    $number = 0
    if ([int]::TryParse($value, [ref]$number)) { return $number }
    return 0
}

# Get-FreeName NAME TAKEN: NAME, or NAME-2, NAME-3... when already in use.
function Get-FreeName([string]$Name, [string[]]$Taken) {
    $candidate = $Name
    $n = 2
    while ($Taken -contains $candidate) {
        $candidate = "$Name-$n"
        $n++
    }
    return $candidate
}

# Get-SuggestedUser: the Windows user name, made valid for Linux.
function Get-SuggestedUser {
    $user = ("$env:USERNAME").ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if (-not $user -or $user -eq 'root') { return 'dev' }
    if ($user -notmatch '^[a-z_]') { $user = "dev$user" }
    if ($user.Length -gt 32) { $user = $user.Substring(0, 32) }
    return $user
}

# Get-GitSetting KEY: a value from the Windows git config, if git exists.
function Get-GitSetting([string]$Key) {
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { return '' }
    $ErrorActionPreference = 'Continue'
    $value = & git.exe config --global --get $Key 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ("$value").Trim()
}

# ConvertTo-WslPath PATH: C:\Users\me -> /mnt/c/Users/me
function ConvertTo-WslPath([string]$Path) {
    if ($Path -match '^([A-Za-z]):\\(.*)$') {
        return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\', '/')
    }
    return $Path
}

# ---------------------------------------------------------------- questionnaire

# Read-Questionnaire: ask everything (or take the defaults with -Yes) and
# return the answers.
function Read-Questionnaire {
    $taken = Get-InstalledDistro
    $catalog = Get-DistroCatalog
    $memoryTotal = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cpuTotal = [Environment]::ProcessorCount

    $defaults = [ordered]@{
        Distro   = 'Ubuntu'
        MemoryGB = [math]::Max(2, [int][math]::Floor($memoryTotal / 2))
        Cpus     = $cpuTotal
        Profile  = 'dev'
        GitName  = Get-GitSetting 'user.name'
        GitEmail = Get-GitSetting 'user.email'
        User     = Get-SuggestedUser
    }

    # Keep the limits already set in ~\.wslconfig, when they make sense here.
    $memorySet = Get-WslConfigNumber 'memory'
    if ($memorySet -ge 1 -and $memorySet -le $memoryTotal) { $defaults.MemoryGB = $memorySet }
    $cpusSet = Get-WslConfigNumber 'processors'
    if ($cpusSet -ge 1 -and $cpusSet -le $cpuTotal) { $defaults.Cpus = $cpusSet }

    if ($RunOptions.Yes) {
        $name = Get-FreeName $defaults.Distro $taken
        return [ordered]@{
            Distro   = $defaults.Distro
            Name     = $name
            Location = Join-Path $HOME "WSL\$name"
            User     = $defaults.User
            MemoryGB = $defaults.MemoryGB
            Cpus     = $defaults.Cpus
            Profile  = $defaults.Profile
            GitName  = $defaults.GitName
            GitEmail = $defaults.GitEmail
        }
    }

    $answers = [ordered]@{}
    $width = ($catalog | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum + 1
    $distroOptions = @($catalog | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = ("{0,-$width} {1}" -f $_.Name, $_.FriendlyName) }
        })
    $answers.Distro = Read-Choice 'Which Linux distribution?' $defaults.Distro $distroOptions

    $answers.Name = Read-Text 'Name for the new distro' (Get-FreeName $answers.Distro $taken) {
        param($value)
        if ($value -notmatch '^[A-Za-z0-9._-]+$') { return 'Use only letters, numbers, dots, dashes and underscores.' }
        if ($taken -contains $value) { return "A distro named $value already exists." }
    }

    $answers.Location = Read-Text 'Install folder' (Join-Path $HOME "WSL\$($answers.Name)") {
        param($value)
        if (-not [IO.Path]::IsPathRooted($value)) { return 'Use a full path, like C:\WSL\Ubuntu.' }
        if ((Test-Path $value) -and (Get-ChildItem -Force -Path $value | Select-Object -First 1)) {
            return 'That folder is not empty; pick another one.'
        }
    }

    $answers.User = Read-Text 'Linux user name' $defaults.User {
        param($value)
        if ($value -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') { return 'Use lowercase letters, numbers, - and _ (start with a letter).' }
        if ($value -eq 'root') { return 'Pick a name other than root.' }
    }

    $answers.MemoryGB = [int](Read-Text "Memory for WSL in GB (shared by all distros; this PC has $memoryTotal GB)" "$($defaults.MemoryGB)" {
            param($value)
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt $memoryTotal) { return "Use a number from 1 to $memoryTotal." }
        })

    $answers.Cpus = [int](Read-Text "CPU cores for WSL (this PC has $cpuTotal)" "$($defaults.Cpus)" {
            param($value)
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt $cpuTotal) { return "Use a number from 1 to $cpuTotal." }
        })

    $profileOptions = @(
        [pscustomobject]@{ Key = 'dev'; Label = 'dev       Recommended: CLI tools, git, Python, Node.js, Docker, Claude Code' }
        [pscustomobject]@{ Key = 'minimal'; Label = 'minimal   Just the essentials: base packages and git' }
        [pscustomobject]@{ Key = 'full'; Label = 'full      Everything available' }
    )
    $answers.Profile = Read-Choice 'What would you like to install? (pick single tools later with the menu inside the distro)' $defaults.Profile $profileOptions

    $answers.GitName = Read-Text 'Git user name' $defaults.GitName
    $answers.GitEmail = Read-Text 'Git email' $defaults.GitEmail {
        param($value)
        if ($value -and $value -notmatch '^[^@\s]+@[^@\s]+$') { return 'That does not look like an email address.' }
    }
    return $answers
}

function Show-Summary($Answers, [bool]$WslReady) {
    Write-Step 'Summary'
    $rows = [ordered]@{
        'Distro'          = $Answers.Distro
        'Name'            = $Answers.Name
        'Install folder'  = $Answers.Location
        'Linux user'      = "$($Answers.User) (the password is asked before the distro is created)"
        'WSL memory/CPUs' = "$($Answers.MemoryGB) GB / $($Answers.Cpus) cores"
        'Tools'           = "profile $($Answers.Profile)"
        'Git identity'    = "$($Answers.GitName) <$($Answers.GitEmail)>"
    }
    foreach ($key in $rows.Keys) {
        Write-Host ('    {0}{1,-16}{2} {3}' -f $C.Ash, $key, $C.Reset, $rows[$key])
    }
    Write-Host ''
    if ($WslReady) {
        Write-Note "$($C.Ash)WSL is already enabled on this PC.$($C.Reset)"
    }
    else {
        Write-Note "$($C.Ash)WSL is not enabled yet: that needs administrator rights and a restart;$($C.Reset)"
        Write-Note "$($C.Ash)wslforge continues by itself after the restart.$($C.Reset)"
    }
}

# Save-Config ANSWERS PATH: write the answers as a wslforge.conf. WSL_* keys
# are for the Windows side; install.sh reads the others inside the distro.
function Save-Config($Answers, [string]$Path) {
    $lines = @(
        "# wslforge settings, written by install.ps1 $WslforgeVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
        '# Plain KEY=value lines. Edit freely and run install.ps1 again.'
        ''
        '# Windows side: the distro to create'
        "WSL_DISTRO=$($Answers.Distro)"
        "WSL_NAME=$($Answers.Name)"
        "WSL_LOCATION=$($Answers.Location)"
        "WSL_USER=$($Answers.User)"
        "WSL_MEMORY_GB=$($Answers.MemoryGB)"
        "WSL_CPUS=$($Answers.Cpus)"
        ''
        '# Linux side: read by install.sh inside the distro'
        "PROFILE=$($Answers.Profile)"
        "GIT_NAME=`"$($Answers.GitName)`""
        "GIT_EMAIL=`"$($Answers.GitEmail)`""
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    # UTF-8 without BOM and LF line endings, so install.sh reads it cleanly.
    $text = ($lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false))
}

# Read-Config PATH: the answers saved by Save-Config.
function Read-Config([string]$Path) {
    if (-not (Test-Path $Path)) { throw "No saved answers in $Path; run without -Resume first." }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            $values[$key] = $value
        }
    }
    foreach ($key in 'WSL_DISTRO', 'WSL_NAME', 'WSL_LOCATION', 'WSL_USER', 'WSL_MEMORY_GB', 'WSL_CPUS') {
        if (-not $values[$key]) { throw "$Path has no $key; run without -Resume to answer again." }
    }
    $profileName = $values['PROFILE']
    if (-not $profileName) { $profileName = 'dev' }
    return [ordered]@{
        Distro   = $values['WSL_DISTRO']
        Name     = $values['WSL_NAME']
        Location = $values['WSL_LOCATION']
        User     = $values['WSL_USER']
        MemoryGB = [int]$values['WSL_MEMORY_GB']
        Cpus     = [int]$values['WSL_CPUS']
        Profile  = $profileName
        GitName  = "$($values['GIT_NAME'])"
        GitEmail = "$($values['GIT_EMAIL'])"
    }
}

# ---------------------------------------------------------------- .wslconfig

# Get-IniValue LINES SECTION KEY: the value of KEY in [SECTION], or ''.
function Get-IniValue([string[]]$Lines, [string]$Section, [string]$Key) {
    $current = ''
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $current = $Matches[1].Trim(); continue }
        if ($current -eq $Section -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$')) {
            return $Matches[1]
        }
    }
    return ''
}

# Edit-IniValue LINES SECTION KEY VALUE: set KEY=VALUE in [SECTION] of a list
# of lines, keeping every other line (and comment) as it was.
function Edit-IniValue([Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key, [string]$Value) {
    $current = ''
    $start = -1
    $lastEntry = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($start -ge 0) { break }
            $current = $Matches[1].Trim()
            if ($current -eq $Section) { $start = $i; $lastEntry = $i }
            continue
        }
        if ($start -lt 0) { continue }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $Lines[$i] = "$Key=$Value"
            return
        }
        if ($line.Trim()) { $lastEntry = $i }
    }
    if ($start -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim()) { $Lines.Add('') }
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
        return
    }
    $Lines.Insert($lastEntry + 1, "$Key=$Value")
}

# Write-WslConfig ANSWERS: memory and processors in ~\.wslconfig. The rest of
# the file stays; a backup is kept the first time wslforge changes it.
function Write-WslConfig($Answers) {
    $memory = "$($Answers.MemoryGB)GB"
    $cpus = "$($Answers.Cpus)"
    $lines = New-Object 'Collections.Generic.List[string]'
    if (Test-Path $WslConfigPath) {
        foreach ($line in [IO.File]::ReadAllLines($WslConfigPath)) { $lines.Add($line) }
    }
    if ((Get-IniValue $lines 'wsl2' 'memory') -eq $memory -and (Get-IniValue $lines 'wsl2' 'processors') -eq $cpus) {
        Write-Success "~\.wslconfig already has $memory and $cpus CPU cores"
        return
    }
    $backup = "$WslConfigPath.wslforge-backup"
    if ((Test-Path $WslConfigPath) -and -not (Test-Path $backup)) {
        Copy-Item -Path $WslConfigPath -Destination $backup
        Write-Note "Backup of the previous file: $backup"
    }
    Edit-IniValue $lines 'wsl2' 'memory' $memory
    Edit-IniValue $lines 'wsl2' 'processors' $cpus
    $text = ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($WslConfigPath, $text, (New-Object Text.UTF8Encoding $false))
    Write-Success "~\.wslconfig: memory=$memory, processors=$cpus"
    Write-Note "$($C.Ash)It applies to every distro after WSL restarts (wsl --shutdown closes all of them).$($C.Reset)"
}

# ---------------------------------------------------------------- running things

# Invoke-Console FILE ARGUMENTS [INPUT] [QUIET]: run a program on this
# console (so Linux gets a real terminal) and return its exit code. INPUT,
# when given, is sent to its stdin as UTF-8. QUIET hides the output unless
# the program fails.
function Invoke-Console([string]$File, [string]$Arguments, [string]$InputText = $null, [bool]$Quiet = $false) {
    $info = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $info.UseShellExecute = $false
    # A UNC current folder (\\wsl.localhost\...) cannot be mapped into Linux.
    $info.WorkingDirectory = $HOME
    if ($null -ne $InputText) { $info.RedirectStandardInput = $true }
    if ($Quiet) {
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -ne $InputText) {
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($InputText)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    }
    $output = ''
    if ($Quiet) { $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd() }
    $process.WaitForExit()
    if ($Quiet -and $process.ExitCode -ne 0) { Write-Host $output.Trim() }
    return $process.ExitCode
}

# Join-Argument ARGS: one Windows command line. No argument here ever holds
# a double quote (they are names, paths and bash code built without them).
function Join-Argument([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        if ($argument -match '[\s;&|]' -or -not $argument) { '"' + $argument + '"' } else { $argument }
    }
    return ($parts -join ' ')
}

# ConvertTo-BashWord TEXT: TEXT as one single-quoted bash word.
function ConvertTo-BashWord([string]$Text) {
    return "'" + $Text.Replace("'", "'\''") + "'"
}

# Invoke-Wsl ARGS [INPUT] [QUIET]: wsl.exe on this console, with UTF-8 output.
function Invoke-Wsl([string[]]$Arguments, [string]$InputText = $null, [bool]$Quiet = $false) {
    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try { return (Invoke-Console 'wsl.exe' (Join-Argument $Arguments) $InputText $Quiet) }
    finally { $env:WSL_UTF8 = $previous }
}

# Invoke-Elevated COMMAND: run a PowerShell command as administrator (Windows
# asks for permission) and return its exit code. Only when really needed.
function Invoke-Elevated([string]$Command) {
    $script = "$Command; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    }
    catch {
        throw 'Administrator rights were not granted, so WSL could not be set up.'
    }
    return $process.ExitCode
}

# Get-ResumeHint CONFIG: the command that continues with the saved answers.
function Get-ResumeHint([string]$ConfigPath) {
    $hint = '.\install.ps1 -Resume'
    if ($ConfigPath -ne [IO.Path]::GetFullPath((Join-Path $StateDir 'wslforge.conf'))) {
        $hint += " -Config `"$ConfigPath`""
    }
    return $hint
}

# Get-InstallRef: what to install inside the distro. -dev versions follow the
# main branch, releases their own tag (same rule as install.sh).
function Get-InstallRef {
    if ($RunOptions.Ref) { return $RunOptions.Ref }
    if ($WslforgeVersion -like '*-dev') { return 'main' }
    return "v$WslforgeVersion"
}

# ---------------------------------------------------------------- WSL itself

# Install-Wsl CONFIG: enable WSL (as administrator) and continue after the
# restart through a RunOnce entry that reuses the saved answers.
function Install-Wsl([string]$ConfigPath) {
    Write-Step 'Enabling WSL'
    Write-Note 'This needs administrator rights: Windows will ask for permission.'
    $code = Invoke-Elevated 'wsl.exe --install --no-distribution'
    # 3010: success, restart required.
    if ($code -ne 0 -and $code -ne 3010) { throw "Enabling WSL failed (exit code $code)." }

    Register-Resume $ConfigPath
    Write-Success 'WSL is enabled. Windows needs a restart to finish.'
    Write-Note 'After the restart, sign in: wslforge opens and continues with your answers.'
    if (-not $RunOptions.Yes -and (Confirm-Answer 'Restart now?')) {
        Restart-Computer -Force
    }
    else {
        Write-Note 'Restart when you are ready.'
    }
}

# Register-Resume CONFIG: keep a copy of this script and run it once at the
# next sign-in with -Resume (RunOnce needs no administrator rights).
function Register-Resume([string]$ConfigPath) {
    $copy = Join-Path $StateDir 'install.ps1'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    if ($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne $copy)) {
        Copy-Item -Path $PSCommandPath -Destination $copy -Force
    }
    elseif ($RunOptions.RepoPath) {
        Copy-Item -Path (Join-Path $RunOptions.RepoPath 'install.ps1') -Destination $copy -Force
    }
    elseif (-not $PSCommandPath) {
        # Run through "irm | iex": there is no file, so fetch the same version.
        Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/$(Get-InstallRef)/install.ps1" -OutFile $copy
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $copy,
        '-Resume', '-Config', $ConfigPath, '-Ui', $RunOptions.Ui)
    if ($RunOptions.Ref) { $arguments += @('-Ref', $RunOptions.Ref) }
    if ($RunOptions.RepoPath) { $arguments += @('-RepoPath', $RunOptions.RepoPath) }
    $command = 'powershell.exe ' + (Join-Argument $arguments)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'wslforge' -Value $command
}

# Install-WslUpdate: "wsl --install --name/--location" needs a recent WSL.
function Install-WslUpdate {
    $version = Get-WslVersion
    if ($version -and $version -ge $MinWslVersion) { return }
    Write-Step 'Updating WSL'
    Write-Note "wslforge needs WSL $MinWslVersion or newer; Windows will ask for permission."
    $code = Invoke-Elevated 'wsl.exe --update'
    $version = Get-WslVersion
    if ($code -ne 0 -or -not $version -or $version -lt $MinWslVersion) {
        throw "Could not update WSL (run 'wsl --update' as administrator and try again with -Resume)."
    }
    Write-Success "WSL $version"
}

# ---------------------------------------------------------------- the distro

# Install-Distro ANSWERS: install the distro under the chosen name and folder.
function Install-Distro($Answers) {
    if ((Get-InstalledDistro) -contains $Answers.Name) {
        Write-Note "$($Answers.Name) already exists; continuing with it."
        return
    }
    Write-Step "Creating $($Answers.Name) ($($Answers.Distro))"
    $code = Invoke-Wsl @('--install', $Answers.Distro, '--name', $Answers.Name, '--location', $Answers.Location, '--no-launch')
    if ($code -ne 0 -or -not ((Get-InstalledDistro) -contains $Answers.Name)) {
        throw "Creating $($Answers.Name) failed (exit code $code)."
    }
    Write-Success "$($Answers.Name) created in $($Answers.Location)"
}

# Initialize-LinuxUser ANSWERS PASSWORD: create the user with sudo, make it
# the default, turn systemd on, and grant passwordless sudo for the install
# (install.sh removes it when it ends). The script goes through stdin, so the
# password never shows up in a command line or a file.
function Initialize-LinuxUser($Answers, [Security.SecureString]$Secret) {
    Write-Step "Creating the Linux user $($Answers.User)"
    $marker = 'WSLFORGE_' + ([guid]::NewGuid().ToString('N'))
    $setup = @'
set -eu
user=__USER__
export DEBIAN_FRONTEND=noninteractive

# sudo and curl: install.sh needs both, and minimal images may lack them.
missing=''
command -v sudo >/dev/null 2>&1 || missing="$missing sudo"
command -v curl >/dev/null 2>&1 || missing="$missing curl"
command -v useradd >/dev/null 2>&1 || missing="$missing shadow"
command -v awk >/dev/null 2>&1 || missing="$missing gawk"
if [ -n "$missing" ]; then
  echo "Installing:$missing"
  # quiet RUN...: run a command, showing its output only when it fails.
  quiet() {
    "$@" >/tmp/wslforge-setup.log 2>&1 || { cat /tmp/wslforge-setup.log >&2; return 1; }
  }
  if command -v apt-get >/dev/null 2>&1; then
    missing=$(echo "$missing" | sed 's/shadow/passwd/')
    quiet apt-get update
    quiet apt-get install -y $missing ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    missing=$(echo "$missing" | sed 's/shadow/shadow-utils/')
    quiet dnf install -y $missing
  elif command -v pacman >/dev/null 2>&1; then
    # A fresh Arch has no pacman keyring yet; partial upgrades are not
    # supported, so this is a full upgrade.
    if ! pacman-key --list-keys >/dev/null 2>&1; then
      quiet pacman-key --init
      quiet pacman-key --populate
    fi
    quiet pacman -Syu --noconfirm --needed $missing
  else
    echo "Please install:$missing" >&2
    exit 1
  fi
  rm -f /tmp/wslforge-setup.log
fi

# UID 1000 when free: the distro's first-run setup then sees the user and
# does not ask to create another one.
if ! id -u "$user" >/dev/null 2>&1; then
  if getent passwd 1000 >/dev/null; then
    useradd -m -s /bin/bash "$user"
  else
    useradd -m -s /bin/bash -u 1000 "$user"
  fi
fi
for group in sudo wheel adm cdrom dip plugdev; do
  if getent group "$group" >/dev/null; then usermod -aG "$group" "$user"; fi
done
# Outside the Debian family there is no "sudo" group, and the default rules
# vary (Arch has none enabled). Give the user sudo with their own password.
# (Sorts before wslforge-setup below.)
if ! getent group sudo >/dev/null; then
  printf '%s ALL=(ALL:ALL) ALL\n' "$user" > /etc/sudoers.d/10-wslforge-user
  chmod 440 /etc/sudoers.d/10-wslforge-user
fi
chpasswd <<'__MARKER__'
__USER__:__PASSWORD__
__MARKER__

# set_key FILE SECTION KEY VALUE: set KEY=VALUE in [SECTION], keep the rest.
set_key() {
  touch "$1"
  awk -v s="$2" -v k="$3" -v v="$4" '
    /^[[:space:]]*\[/ {
      if (in_sec && !done) { print k "=" v; done = 1 }
      sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); in_sec = (sec == s); print; next
    }
    in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (in_sec && !done) { print k "=" v; done = 1 }; if (!done) { print ""; print "[" s "]"; print k "=" v } }
  ' "$1" > "$1.new" && mv "$1.new" "$1"
}
set_key /etc/wsl.conf boot systemd true
set_key /etc/wsl.conf user default "$user"

printf '%s ALL=(ALL) NOPASSWD: ALL
' "$user" > /etc/sudoers.d/wslforge-setup
chmod 440 /etc/sudoers.d/wslforge-setup
echo "User $user is ready."
# end
'@
    $setup = $setup.Replace("`r", '').Replace('__MARKER__', $marker).Replace('__USER__', $Answers.User)
    $setup = $setup.Replace('__PASSWORD__', (ConvertFrom-Secret $Secret))
    $code = Invoke-Wsl @('-d', $Answers.Name, '-u', 'root', '--cd', '/', '--', 'bash', '-s') $setup
    $setup = $null
    if ($code -ne 0) { throw "Setting up the user $($Answers.User) failed (exit code $code)." }

    Invoke-Wsl @('--manage', $Answers.Name, '--set-default-user', $Answers.User) $null $true | Out-Null
    # Restart the distro so systemd and the default user take effect.
    Invoke-Wsl @('--terminate', $Answers.Name) $null $true | Out-Null
    Write-Success "$($Answers.User) is the default user, with sudo; systemd is on"
}

# Invoke-LinuxInstaller ANSWERS CONFIG: run install.sh inside the distro as
# the new user, with the saved answers. Returns its exit code.
function Invoke-LinuxInstaller($Answers, [string]$ConfigPath) {
    Write-Step "Installing your tools in $($Answers.Name)"
    $config = ConvertTo-BashWord (ConvertTo-WslPath $ConfigPath)
    $source = $null
    try {
        if ($RunOptions.RepoPath) {
            # A copy on C: so the distro can read it (also from \\wsl.localhost).
            $source = Join-Path ([IO.Path]::GetTempPath()) ('wslforge-src-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $source | Out-Null
            Get-ChildItem -Force -Path $RunOptions.RepoPath | Where-Object { $_.Name -ne '.git' } |
                Copy-Item -Destination $source -Recurse -Force
            $script = ConvertTo-BashWord ((ConvertTo-WslPath $source) + '/install.sh')
            $command = "bash $script --config $config --from-windows"
        }
        else {
            $ref = Get-InstallRef
            $url = ConvertTo-BashWord "$RawUrl/$ref/install.sh"
            $command = "curl -fsSL $url | bash -s -- --ref $(ConvertTo-BashWord $ref) --config $config --from-windows"
        }
        # The distro has just started: let systemd finish booting first, so
        # services (like Docker) can be enabled right away.
        $command = '(timeout 90 systemctl is-system-running --wait >/dev/null 2>&1 || true); ' + $command
        return (Invoke-Wsl @('-d', $Answers.Name, '-u', $Answers.User, '--cd', '~', '--', 'bash', '-lc', $command))
    }
    finally {
        # install.sh drops the temporary sudo rule itself; this covers a crash.
        Invoke-Wsl @('-d', $Answers.Name, '-u', 'root', '--cd', '/', '--', 'rm', '-f', '/etc/sudoers.d/wslforge-setup') $null $true | Out-Null
        if ($source) { Remove-Item -Recurse -Force -Path $source -ErrorAction SilentlyContinue }
    }
}

# Invoke-Setup ANSWERS CONFIG: everything after the questions.
function Invoke-Setup($Answers, [string]$ConfigPath) {
    if (-not (Test-WslReady)) {
        Install-Wsl $ConfigPath
        return 0
    }
    Install-WslUpdate

    Write-Step 'Linux password'
    $secret = Read-Password $Answers.User

    Install-Distro $Answers
    Initialize-LinuxUser $Answers $secret
    $secret.Dispose()

    Write-Step 'WSL limits'
    Write-WslConfig $Answers

    $code = Invoke-LinuxInstaller $Answers $ConfigPath
    Write-Host ''
    if ($code -ne 0) {
        Write-Caution "Some tools did not install (exit code $code). Details: ~/.wslforge/install.log in $($Answers.Name)."
        Write-Note "To try again: $($C.Ember)$(Get-ResumeHint $ConfigPath)$($C.Reset) (it skips what is already done)."
        return 1
    }
    Write-Success "$($Answers.Name) is ready."
    Write-Note "Open it with $($C.Ember)wsl -d $($Answers.Name)$($C.Reset) or from the Windows Terminal menu."
    return 0
}

# ---------------------------------------------------------------- main

function Invoke-Main {
    if ($RunOptions.Help) {
        Show-Usage
        return 0
    }
    $configPath = $RunOptions.Config
    if (-not $configPath) { $configPath = Join-Path $StateDir 'wslforge.conf' }
    $configPath = [IO.Path]::GetFullPath($configPath)

    if (-not $RunOptions.Yes) { Initialize-Ui }
    Show-Banner "wslforge $WslforgeVersion" 'Set up WSL for development on this PC'

    if ($RunOptions.Resume) {
        $answers = Read-Config $configPath
        Write-Note "Using the answers saved in $configPath"
    }
    else {
        $answers = Read-Questionnaire
    }
    Show-Summary $answers (Test-WslReady)

    if ($RunOptions.ConfigOnly) {
        if (-not $RunOptions.Yes) {
            Write-Host ''
            if (-not (Confirm-Answer 'Save these answers?')) {
                Write-Note 'Nothing was saved.'
                return 1
            }
        }
        Save-Config $answers $configPath
        Write-Host ''
        Write-Success "Answers saved to $configPath"
        Write-Note "Set everything up with them later: $($C.Ember)$(Get-ResumeHint $configPath)$($C.Reset)"
        return 0
    }

    if (-not $RunOptions.Yes -and -not $RunOptions.Resume) {
        Write-Host ''
        if (-not (Confirm-Answer "Set up $($answers.Name) now?")) {
            Write-Note 'Nothing was changed.'
            return 1
        }
    }
    if (-not $RunOptions.Resume) {
        Save-Config $answers $configPath
        Write-Success "Answers saved to $configPath"
    }
    return (Invoke-Setup $answers $configPath)
}

$originalEncoding = [Console]::OutputEncoding
$exitCode = 1
try {
    # gum and wsl.exe write UTF-8; read it as such.
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    $exitCode = Invoke-Main
}
catch {
    Write-Host "$($C.Red)ERROR:$($C.Reset) $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    [Console]::OutputEncoding = $originalEncoding
}
# "exit" would close the window when run through "irm ... | iex".
if ($PSCommandPath) { exit $exitCode }
