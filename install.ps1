#Requires -Version 5.1
<#
wslforge for Windows: a few questions (every one has a default), a summary,
and a wslforge.conf with the answers for the distro to be created.

Run it:
  irm https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.ps1 | iex

With options:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.ps1))) -Yes

This file must stay plain ASCII: Windows PowerShell 5.1 misreads other
characters in files without a BOM. Symbols are built with [char] instead.
#>
param(
    # Accept every default without asking.
    [switch]$Yes,
    # Menu style: auto (gum when possible), gum or text.
    [ValidateSet('auto', 'gum', 'text')]
    [string]$Ui = 'auto',
    # Where to save the answers (default: ~\.wslforge\wslforge.conf).
    [string]$OutFile = '',
    [switch]$Help
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Functions read the parameters from here. Script parameters used only inside
# functions look unused to PSScriptAnalyzer (PSReviewUnusedParameter).
$RunOptions = @{ Yes = [bool]$Yes; Ui = $Ui; OutFile = $OutFile; Help = [bool]$Help }

$WslforgeVersion = '0.2.0-dev'
$GumVersion = '2.0.2'
$StateDir = Join-Path $HOME '.wslforge'
$DistroListUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'

# Families install.sh supports today (apt). Others arrive in Phase 4.
$SupportedFamilies = @('Ubuntu', 'Debian', 'kali')
$FallbackDistros = @(
    [pscustomobject]@{ Name = 'Ubuntu'; FriendlyName = 'Ubuntu' }
    [pscustomobject]@{ Name = 'Ubuntu-24.04'; FriendlyName = 'Ubuntu 24.04 LTS' }
    [pscustomobject]@{ Name = 'Debian'; FriendlyName = 'Debian GNU/Linux' }
    [pscustomobject]@{ Name = 'kali-linux'; FriendlyName = 'Kali Linux Rolling' }
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
  .\install.ps1 [-Yes] [-Ui auto|gum|text] [-OutFile PATH]

Options:
  -Yes        Accept every default without asking
  -Ui NAME    Menu style: auto (default), gum or text
  -OutFile    Where to save the answers (default: ~\.wslforge\wslforge.conf)
  -Help       Show this help

This version asks the questions and saves the answers. Creating the distro
from them arrives in the next version.
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
        & $UiState.Gum style --border rounded --border-foreground $Forge.Ember --padding '0 2' --margin '1 0 0 0' $bold $Subtitle
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
        Write-Host ('  {0}) {1}' -f ($i + 1), $Options[$i].Label)
    }
    while ($true) {
        $reply = Read-Host "  Choose [default: $Default]"
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
            $value = (Read-Host "  $Prompt$hint").Trim()
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
    $distroOptions = @($catalog | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = ('{0,-14} {1}' -f $_.Name, $_.FriendlyName) }
        })
    $answers.Distro = Read-Choice 'Which Linux distribution? (Fedora, Arch and others come later)' $defaults.Distro $distroOptions

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
        'Linux user'      = "$($Answers.User) (the password is asked right before the distro is created)"
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
        Write-Note "$($C.Ash)WSL is not enabled yet: it will need administrator rights and maybe a restart.$($C.Reset)"
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

# ---------------------------------------------------------------- main

function Invoke-Main {
    if ($RunOptions.Help) {
        Show-Usage
        return 0
    }
    $configPath = $RunOptions.OutFile
    if (-not $configPath) { $configPath = Join-Path $StateDir 'wslforge.conf' }
    $configPath = [IO.Path]::GetFullPath($configPath)

    if (-not $RunOptions.Yes) { Initialize-Ui }
    Show-Banner "wslforge $WslforgeVersion" 'Set up WSL for development on this PC'

    $answers = Read-Questionnaire
    $wslReady = Test-WslReady
    Show-Summary $answers $wslReady

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
    Write-Host ''
    Write-Note 'Creating the distro from these answers arrives in the next version of wslforge.'
    Write-Note 'Meanwhile, inside an existing distro you can already use the Linux settings:'
    Write-Note "  $($C.Ember)./install.sh --config $(ConvertTo-WslPath $configPath)$($C.Reset)"
    return 0
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
