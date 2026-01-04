<#
.SYNOPSIS
    GitPrompt-Ops v7.5 (Enterprise Edition)
.DESCRIPTION
    The Universal Git Prompt Manager.
    Separation of Code (Public) and Data (Private).
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Position=0)]
    [ValidateSet("menu","up","sync","bump","rollback","new","doctor","index","publish")]
    [string]$Command = "menu",

    [Parameter(HelpMessage="Domain (strategy, coding, ops, trading)")]
    [ValidateSet("strategy","coding","ops","trading")]
    [string]$Domain,

    [Parameter(HelpMessage="Prompt Name (slug)")]
    [ValidateScript({
        if ($_ -match '[\\\/\.\:\*\?\"\<\>\|]') {
            throw "Name contains invalid characters. Use letters, numbers, spaces, hyphens, underscores only."
        }
        $true
    })]
    [string]$Name,

    [Parameter(HelpMessage="Path to source file")]
    [ValidateScript({
        if (-not [string]::IsNullOrWhiteSpace($_) -and -not (Test-Path $_ -PathType Leaf)) {
            throw "File not found: $_"
        }
        $true
    })]
    [string]$From,

    [Parameter(HelpMessage="Bump type (major, minor, patch)")]
    [ValidateSet("major","minor","patch")]
    [string]$Bump = "minor",

    [Parameter(HelpMessage="Target version for rollback")]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ToVersion,

    [Parameter(HelpMessage="Initial version for new prompt")]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [ValidateScript({
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            $normalized = [System.IO.Path]::GetFullPath($_)
            if ($normalized -notlike "*prompts*") {
                throw "Path must be within prompts directory structure"
            }
        }
        $true
    })]
    [string]$Path,

    [switch]$Readme,

    [ValidateScript({
        if (-not [string]::IsNullOrWhiteSpace($_) -and -not (Test-Path $_ -PathType Leaf)) {
            throw "README file not found: $_"
        }
        $true
    })]
    [string]$ReadmeFrom,

    [ValidateSet("prompt","domain","root")]
    [string]$ReadmeScope = "prompt",

    [ValidateSet("replace","section")]
    [string]$ReadmeMode = "replace",

    [switch]$Yes,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NormalizeEol,

    [ValidatePattern('^https?://.*$')]
    [string]$RepoUrl = ""
)

# Script parameters are used within helper functions via script scope.
$null = $Path, $ReadmeFrom, $ReadmeScope, $ReadmeMode, $Yes, $Force, $DryRun, $NormalizeEol, $RepoUrl

# ==========================================
# CONFIGURATION MANAGER
# ==========================================
function Get-GitPromptScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return (Get-Location).Path
}

$script:Config = $null
$script:ConfigFile = Join-Path (Get-GitPromptScriptRoot) "gitprompt-config.json"

function Export-GitPromptConfiguration {
    if ([string]::IsNullOrWhiteSpace($script:ConfigFile)) {
        $script:ConfigFile = Join-Path (Get-GitPromptScriptRoot) "gitprompt-config.json"
    }
    $json = $script:Config | ConvertTo-Json -Depth 4
    $json | Set-Content -Path $script:ConfigFile -Encoding UTF8

    # Self-Healing .gitignore: ignore le fichier de config privé
    $gitignore = Join-Path (Get-GitPromptScriptRoot) ".gitignore"
    if (-not (Test-Path $gitignore) -or (Get-Content $gitignore -Raw) -notmatch "gitprompt-config.json") {
        Add-Content -Path $gitignore -Value "`ngitprompt-config.json"
    }
}

function Initialize-GitPromptSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    while ($true) {
        Clear-Host
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "   GitPrompt-Ops | FIRST RUN SETUP" -ForegroundColor White
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "1. Scan PC for Git Repos ($env:USERPROFILE)"
        Write-Host "2. Clone Private Repo (URL)"
        Write-Host "3. Create Local Folder (Offline)"

        $choice = Read-Host "Choose (1-3)"
        $repoPath = ""

        switch ($choice) {
            '1' {
                Write-Host "Scanning..." -ForegroundColor Yellow
                $repos = Get-ChildItem -Path $env:USERPROFILE -Directory -Recurse -Depth 3 -Filter ".git" -ErrorAction SilentlyContinue |
                    Select-Object @{N='Path';E={$_.Parent.FullName}}
                if ($repos -and $repos.Count -gt 0) {
                    for ($i=0; $i -lt $repos.Count; $i++) { Write-Host "$($i+1)) $($repos[$i].Path)" }
                    $sel = Read-Host "Select #"
                    if ($sel -match '^\d+$' -and $sel -le $repos.Count) { $repoPath = $repos[$sel-1].Path }
                } else {
                    Write-Warning "Aucun repo Git detecte. Utilise l'option 2 ou 3."
                }
            }
            '2' {
                $url = Read-Host "Git URL"
                $name = (Split-Path $url -Leaf) -replace '\.git$',''
                $target = Join-Path (Split-Path $MyInvocation.PSCommandPath) $name
                git clone $url $target
                if ($LASTEXITCODE -eq 0) { $repoPath = $target }
            }
            '3' {
                $name = Read-Host "Folder Name"
                $repoPath = Join-Path (Split-Path $MyInvocation.PSCommandPath) $name
                New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
            }
            default {
                Write-Warning "Choix invalide. Entrez 1, 2 ou 3."
            }
        }

        if ($repoPath) { break }
        Write-Host ""
        Write-Host "Recommence..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }

    $script:Config = @{
        RepoPath = $repoPath
        RepoName = Split-Path $repoPath -Leaf
        Domains  = @('strategy', 'coding', 'ops', 'trading')
        Version  = "7.5.0"
    }
    Export-GitPromptConfiguration
}

function Import-GitPromptConfiguration {
    if (Test-Path $script:ConfigFile) {
        try {
            $script:Config = Get-Content -Path $script:ConfigFile -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Config corrupt. Re-running setup..."
            Initialize-GitPromptSetup
        }
    } else {
        Initialize-GitPromptSetup
    }
}


# ==========================================
# INITIALIZATION
# ==========================================
Import-GitPromptConfiguration
if ($script:Config.RepoPath) { Set-Location $script:Config.RepoPath }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# SECURITY: ReDoS Protection
if ($PSVersionTable.PSVersion.Major -ge 7) {
    try {
        [System.Text.RegularExpressions.Regex]::s_defaultMatchTimeout = [TimeSpan]::FromSeconds(2)
    } catch {
        Write-Verbose "Regex default timeout not available: $($_.Exception.Message)"
    }
}

# Helpers: Output
function Write-Info([string]$m){ Write-Host ("[Info]  " + $m) }
function Write-Ok([string]$m){ Write-Host ("[OK]    " + $m) -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host ("[WARN]  " + $m) -ForegroundColor Yellow }
function Write-Fail([string]$m){ Write-Host ("[FAIL]  " + $m) -ForegroundColor Red }

function Write-Box([string]$title, [string[]]$lines){
  Write-Host ""
  Write-Host ("==== " + $title + " ====") -ForegroundColor Cyan
  foreach($l in $lines){ Write-Host $l }
  Write-Host ("=" * (8 + $title.Length)) -ForegroundColor Cyan
  Write-Host ""
}





# -------------------------
# Git detection / repo root
# -------------------------
function Test-GitInstalled {
  try {
    $gitVersion = & git --version 2>$null
    return [bool]$gitVersion
  } catch {
    return $false
  }
}


# -------------------------
# Corporate/Firewall helpers (v3.3)
# -------------------------
function Get-SystemProxyUri([string]$testUrl = "https://github.com"){
  try {
    $uri = [Uri]$testUrl
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if ($null -eq $proxy) { return $null }
    $puri = $proxy.GetProxy($uri)
    if ($null -eq $puri) { return $null }
    if ($puri.AbsoluteUri -eq $uri.AbsoluteUri) { return $null }
    return $puri.AbsoluteUri
  } catch { return $null }
}

function Enable-SystemProxyForSession {
  try {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if ([System.Net.WebRequest]::DefaultWebProxy) {
      [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }
  } catch {
    Write-Verbose "Failed to apply system proxy to session: $($_.Exception.Message)"
  }
}

function Set-GitProxyFromSystem {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([bool])]
  param()
  $proxyUri = Get-SystemProxyUri
  if ([string]::IsNullOrWhiteSpace($proxyUri)) { return $false }
  try {
    if ($PSCmdlet.ShouldProcess("git config --global http.proxy/https.proxy", "Apply proxy $proxyUri")) {
      & git config --global http.proxy "$proxyUri" 2>$null | Out-Null
      & git config --global https.proxy "$proxyUri" 2>$null | Out-Null
    }
    Write-Ok "Proxy détecté et appliqué à Git: $proxyUri"
    return $true
  } catch {
    Write-Warn "Proxy détecté mais Configuration Git proxy impossible."
    return $false
  }
}

function Test-GitHubConnectivity {
  Enable-SystemProxyForSession
  try {
    Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}

function Install-GitWizard {
  Write-Box "INSTALLATION GIT" @(
    "Git n'est pas détecté sur cette machine.",
    "Le script peut tenter winget, siNo guider l'installation manuelle/portable."
  )

  $proxyUri = Get-SystemProxyUri
  if ($proxyUri) {
    Write-Warn "Proxy d'entreprise détecté: $proxyUri"
  }

  Write-Host ""
  Write-Host "Choisis une méthode:" -ForegroundColor Yellow
  Write-Host "[1] Installer via winget (si disponible/autorisé)" -ForegroundColor Cyan
  Write-Host "[2] Installer manuellement (Git for Windows)" -ForegroundColor Cyan
  Write-Host "[3] Installer en mode portable (sans droits admin)" -ForegroundColor Cyan
  Write-Host "[0] Cancel" -ForegroundColor Cyan

  $c = Read-Host "Choix (0-3)"
  if ($c -eq "0") { throw "Git requis. Installation annulée." }

  if ($c -eq "1") {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
      Write-Warn "winget introuvable (ou désactivé)."
      Write-Info "Astuce: 'winget --Info' peut indiquer des politiques d'entreprise."
      $c = "2"
    } else {
      try {
        Enable-SystemProxyForSession
        Write-Info "Commande: winget install --id Git.Git -e --source winget"
        $wingetArgs = "install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements"
        $p = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "winget exit code: $($p.ExitCode)" }
        Write-Ok "Git installé. Ferme et rouvre PowerShell puis relance le script."
        exit
      } catch {
        Write-Warn "Installation winget échouée (souvent bloquée par firewall/policy)."
        $c = "2"
      }
    }
  }

  if ($c -eq "2") {
    Write-Box "INSTALLATION MANUELLE" @(
      "Télécharge Git for Windows (Standalone Installer) depuis:",
      "https://git-scm.com/downloads/win",
      "Puis relance ce script."
    )
    throw "Git No installé"
  }

  if ($c -eq "3") {
    Write-Box "INSTALLATION PORTABLE" @(
      "Utilise l'édition Portable (thumbdrive) depuis:",
      "https://git-scm.com/downloads/win",
      "Puis ajoute le dossier 'cmd' de PortableGit au PATH et relance."
    )
    throw "Git No installé"
  }
}

function Initialize-GitIdentityWizard {
  Write-Box "Configuration GIT" @("Configuration de user.name / user.email / core.autocrlf")

  $defName = "BznDEvops"
  $defEmail = "BznDEvops@gmail.com"

  $uName = Read-Host "Git user.name [$defName]"
  if ([string]::IsNullOrWhiteSpace($uName)) { $uName = $defName }

  $uEmail = Read-Host "Git user.email [$defEmail]"
  if ([string]::IsNullOrWhiteSpace($uEmail)) { $uEmail = $defEmail }

  & git config --global user.name "$uName" 2>$null | Out-Null
  & git config --global user.email "$uEmail" 2>$null | Out-Null
  & git config --global core.autocrlf true 2>$null | Out-Null

  Write-Ok "Identité Git configurée: $uName <$uEmail>"
}

function Initialize-GitEnvironment {
  if (-not (Test-GitInstalled)) { Install-GitWizard }
  Set-GitProxyFromSystem | Out-Null
  try { Confirm-GitIdentity } catch { Initialize-GitIdentityWizard }
}

function Invoke-AutoSetup {
  param([string]$targetDir)

  Write-Box "AUTO-SETUP (New PC)" @(
    "Repo Prompt-Lab No détecté dans le dossier courant.",
    "Le script peut cloner automatiquement le repo GitHub."
  )

  Initialize-GitEnvironment

  if (-not (Test-GitHubConnectivity)) {
    Write-Warn "Accès à https://github.com semble bloqué (firewall/proxy/SSL inspection)."
    Write-Info "Si SSL est intercepté: demande à l'IT d'ajouter le certificat racine corporate dans Windows (Trusted Root)."
    Write-Info "Évite de désactiver http.sslVerify (No recommandé)."
  }

  $repoUrl = if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) { $RepoUrl } else { "https://github.com/BzNdevOps/prompt-lab.git" }
  Write-Host "Repo: $repoUrl" -ForegroundColor Cyan

  $choice = Read-Host "Cloner maintenant ? (Y/N)"
  if ($choice.ToUpperInvariant() -ne "Y") { throw "Setup annulé" }

  $cloneDir = Join-Path $targetDir "prompt-lab"
  if (Test-Path $cloneDir) { $cloneDir = Join-Path $targetDir ("prompt-lab_" + (Get-Date -Format "yyyyMMdd_HHmmss")) }

  Write-Info "Clonage dans: $cloneDir"
  & git clone $repoUrl $cloneDir 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

  Write-Ok "Clone terminé."
  Write-Info "Ouvre un terminal dans: $cloneDir"
  Write-Info "Puis lance: .\\promptlab.ps1"
  exit
}

function Get-RepoRoot {
  $dir = (Get-Location).Path
  $maxDepth = 20
  $depth = 0

  while ($dir -and $depth -lt $maxDepth) {
    if (Test-Path (Join-Path $dir ".git")) { return $dir }
    if (Test-Path (Join-Path $dir "prompts")) { return $dir }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir) { break }
    $dir = $parent
    $depth++
  }

  return $null
}

function Invoke-RepoScanner {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $defaultRoot = $env:USERPROFILE
  $rootInput = Read-Host "Root folder (ENTER for $defaultRoot, or ALL)"
  $roots = @()
  if ([string]::IsNullOrWhiteSpace($rootInput)) {
    $roots = @($defaultRoot)
  } elseif ($rootInput.ToUpperInvariant() -eq "ALL") {
    $roots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root.TrimEnd("\") })
  } else {
    $roots = @($rootInput)
  }

  $depthInput = Read-Host "Max depth (ENTER for 10, 0 = unlimited)"
  $maxDepth = 10
  if (-not [string]::IsNullOrWhiteSpace($depthInput)) {
    if (-not [int]::TryParse($depthInput, [ref]$maxDepth) -or $maxDepth -lt 0) {
      throw "Invalid depth. Use 0 or a positive number."
    }
  }

  $includeReparse = Read-Host "Include OneDrive/links (reparse points)? (Y/N) [Y]"
  $allowReparse = $true
  if (-not [string]::IsNullOrWhiteSpace($includeReparse) -and $includeReparse.ToUpperInvariant() -ne "Y") {
    $allowReparse = $false
  }

  $depthLimit = if ($maxDepth -eq 0) { [int]::MaxValue } else { $maxDepth }
  $repos = New-Object System.Collections.Generic.List[string]
  $visited = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })

    while ($queue.Count -gt 0) {
      $item = $queue.Dequeue()
      if (-not $visited.Add($item.Path)) { continue }

      $gitPath = Join-Path $item.Path ".git"
      if (Test-Path $gitPath) {
        $repos.Add($item.Path) | Out-Null
      }

      if ($item.Depth -ge $depthLimit) { continue }

      try {
        $children = Get-ChildItem -Path $item.Path -Directory -Force -ErrorAction SilentlyContinue
      } catch {
        Write-Warning ("Scan failed for {0}: {1}" -f $item.Path, $_.Exception.Message)
        continue
      }

      foreach ($child in $children) {
        if (-not $allowReparse -and ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
        if ($child.Name -eq ".git") { continue }
        $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = ($item.Depth + 1) })
      }
    }
  }

  $uniqueRepos = @($repos | Select-Object -Unique | Sort-Object)
  if (-not $uniqueRepos -or $uniqueRepos.Count -eq 0) {
    Write-Warning "No Git repos found."
    return
  }

  Write-Host ""
  Write-Host "Git repos found: $($uniqueRepos.Count)" -ForegroundColor Yellow
  for ($i = 0; $i -lt $uniqueRepos.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i + 1), $uniqueRepos[$i])
  }

  Write-Host ""
  Write-Host "Delete options:" -ForegroundColor Yellow
  Write-Host "[A] Delete ALL" -ForegroundColor Cyan
  Write-Host "[S] Select numbers" -ForegroundColor Cyan
  Write-Host "[Q] Quit" -ForegroundColor Cyan
  $mode = Read-Host "Choice (A/S/Q)"
  if ($mode.ToUpperInvariant() -eq "Q") { return }

  $selected = New-Object System.Collections.Generic.List[string]
  if ($mode.ToUpperInvariant() -eq "A") {
    $selected.AddRange($uniqueRepos)
  } elseif ($mode.ToUpperInvariant() -eq "S") {
    $selection = Read-Host "Enter numbers (comma-separated)"
    $parts = $selection -split "[,;\s]+" | Where-Object { $_ }
    foreach ($p in $parts) {
      $n = 0
      if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $uniqueRepos.Count) {
        $selected.Add($uniqueRepos[$n - 1])
      }
    }
  } else {
    Write-Warning "Invalid choice."
    return
  }

  if ($selected.Count -eq 0) {
    Write-Warning "No valid selection."
    return
  }

  Write-Host ""
  Write-Host "Selected repos to delete: $($selected.Count)" -ForegroundColor Yellow
  Write-Host "Type DELETE to confirm." -ForegroundColor Red
  $confirmAll = Read-Host "Confirm"
  if ($confirmAll -ne "DELETE") { return }

  $scriptRoot = Get-GitPromptScriptRoot
  $configRoot = $script:Config.RepoPath

  foreach ($repo in $selected | Select-Object -Unique) {
    if (-not (Test-Path $repo -PathType Container)) { continue }
    if ($repo -eq $scriptRoot -or $repo -eq $configRoot) {
      Write-Warning "Skipping protected repo: $repo"
      $confirm = Read-Host "Type DELETE to remove anyway"
      if ($confirm -ne "DELETE") { continue }
    }
    if ($PSCmdlet.ShouldProcess($repo, "Delete repo folder")) {
      try {
        Remove-Item -Path $repo -Recurse -Force
        Write-Ok "Deleted: $repo"
      } catch {
        Write-Warn "Delete failed: $repo ($($_.Exception.Message))"
      }
    }
  }
}


function New-RepoDirectory {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$p)
  if (-not $p) { throw "Path cannot be null" }
  $repoRoot = Get-RepoRoot
  $fullPath = [System.IO.Path]::GetFullPath($p)

  if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Security violation: Path outside repo root: $fullPath"
  }

  if (-not (Test-Path $p)) {
    if(-not $DryRun -and $PSCmdlet.ShouldProcess($p, "Create directory")) {
      New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
  }
}

function ConvertTo-LfEol([string]$text){
  return ($text -replace "`r`n", "`n") -replace "`r", "`n"
}

function Set-TextFile {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$path, [string]$content)
  if (-not $path) { throw "Path cannot be null" }

  $dir = Split-Path $path -Parent
  New-RepoDirectory $dir

  if ($NormalizeEol){ $content = ConvertTo-LfEol $content }

  if ($DryRun -or -not $PSCmdlet.ShouldProcess($path, "Write file")){
    Write-Info "DRY-RUN: would write file: $path"
    return
  }

  try {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
  } catch [System.UnauthorizedAccessException] {
    throw "Access denied writing to: $path (check permissions)"
  } catch {
    throw "Failed to write file: $path - $($_.Exception.Message)"
  }
}

function Copy-FileBackup {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$repoRoot, [string]$filePath)
  if (-not (Test-Path $filePath)) { return $null }

  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $backupRoot = Join-Path $repoRoot (".backup\" + $ts)
  $relative = $filePath

  if ($filePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)){
    $relative = $filePath.Substring($repoRoot.Length).TrimStart("\","/")
  }

  $dest = Join-Path $backupRoot $relative
  $destDir = Split-Path $dest -Parent
  New-RepoDirectory $destDir

  if ($DryRun -or -not $PSCmdlet.ShouldProcess($dest, "Backup file")){
    Write-Info "DRY-RUN: would backup '$filePath' -> '$dest'"
    return $dest
  }

  Copy-Item -Path $filePath -Destination $dest -Force
  Write-Info "Backed up: $relative"
  return $dest
}

# -------------------------
# Slug / versioning
# -------------------------
function ConvertTo-Slug([string]$s){
  if ([string]::IsNullOrWhiteSpace($s)) { throw "Name vide." }

  if ($s -match '[\\\/\.\:\*\?\"\<\>\|]') {
    throw "Invalid characters in name/slug"
  }

  $x = $s.Trim().ToLowerInvariant()
  $x = $x -replace '[\s\-]+','_'
  $x = $x -replace '[^a-z0-9_]+',''
  $x = $x -replace '_{2,}','_'
  $x = $x.Trim('_')

  if ($x.Length -lt 2) { throw "Name/slug invalide après normalisation (trop court)." }
  if ($x -match '^\d+$') { throw "Name/slug cannot be only numbers" }

  return $x
}

function Get-DomainPrefix([string]$domain){
  switch($domain){
    "strategy" { "STR" }
    "coding"   { "COD" }
    "ops"      { "OPS" }
    "trading"  { "TRD" }
    default    { throw "Domaine invalide: $domain" }
  }
}

function ConvertTo-Version([string]$v){
  if ([string]::IsNullOrWhiteSpace($v)) { return [version]"0.0.0" }

  if ($v -notmatch '^\d+\.\d+(\.\d+)?$') {
    throw "Version invalide: $v (attendu format: 1.9 ou 1.9.1)"
  }

  $parts = $v.Trim().Split(".")
  if ($parts.Count -eq 2) { return [version]("{0}.{1}.0" -f $parts[0], $parts[1]) }
  if ($parts.Count -ge 3) { return [version]("{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2]) }
  throw "Version invalide: $v"
}

function Format-Version([version]$v){
  return ("{0}.{1}.{2}" -f $v.Major, $v.Minor, $v.Build)
}

function Get-NextVersion([version]$v, [string]$bump){
  switch($bump){
    "patch" { return [version]("{0}.{1}.{2}" -f $v.Major, $v.Minor, ($v.Build + 1)) }
    "minor" { return [version]("{0}.{1}.0" -f $v.Major, ($v.Minor + 1)) }
    "major" { return [version]("{0}.0.0" -f ($v.Major + 1)) }
    default { throw "Bump invalide: $bump" }
  }
}

# -------------------------
# Markdown detection + safe conversion
# -------------------------
function Test-IsMarkdown([string]$text){
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  $score = 0

  try {
    if ($text -match '(?m)^\s*#\s+') { $score += 2 }
    if ($text -match '(?m)^\s*##\s+') { $score += 2 }
    if ($text -match '(?m)^\s*[-\*]\s+') { $score += 1 }
    if ($text -match '(?m)^\s*\d+\.\s+') { $score += 1 }
    if ($text -match '```') { $score += 3 }
    if ($text -match '\[[^\]]+\]\([^\)]+\)') { $score += 2 }
    if ($text -match '(?m)^\s*>\s+') { $score += 1 }
    if ($text -match '(?m)^\s*\|.+\|') { $score += 2 }
  } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
    Write-Warn 'Regex timeout in Markdown detection - defaulting to safe conversion'
    return $false
  }

  return ($score -ge 3)
}

function Test-YamlLike([string]$text){
  try {
    return ($text -match '(?m)^\s*(metadata|role|modes|principes_core|donnees_critiques|benchmarks|modules_avances|format_livrable)\s*:')
  } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
    return $false
  }
}

function Convert-ToMarkdownSafe([string]$text, [string]$title="Source"){
  $t = $text.TrimEnd()
  $out = @()
  $out += "# $title"
  $out += ""
  if (Test-YamlLike $t){
    $out += '```yaml'
    $out += $t
    $out += '```'
  } else {
    $out += '```text'
    $out += $t
    $out += '```'
  }
  $out += ""
  return ($out -join "`n")
}

function Read-TextFromFile([string]$p){
  if (-not (Test-Path $p)) { throw "Fichier introuvable: $p" }

  $repoRoot = Get-RepoRoot
  $fullPath = [System.IO.Path]::GetFullPath($p)

  if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Warn "Reading file outside repo: $fullPath"
    if (-not $Yes -and -not $Force) {
      $confirm = Read-Host "Continue? (Y/N)"
      if ($confirm.ToLowerInvariant() -ne "y") { throw "Cancelled by user" }
    }
  }

  try {
    $content = Get-Content -Path $p -Raw -Encoding UTF8
    if ($content.Length -gt 0 -and [int][char]$content[0] -eq 0xFEFF) {
      $content = $content.Substring(1)
    }
    return $content
  } catch {
    return Get-Content -Path $p -Raw
  }
}

function Read-TextFromPaste([string]$label){
  Write-Host ""
  Write-Host ('Colle ton texte pour: ' + $label) -ForegroundColor Yellow
  Write-Host 'Termine par une ligne contenant exactement: END' -ForegroundColor Yellow
  Write-Host '(Timeout: 5 minutes)' -ForegroundColor DarkGray

  $lines = New-Object System.Collections.Generic.List[string]
  $startTime = Get-Date
  $timeout = [TimeSpan]::FromMinutes(5)

  while ($true){
    Set-Location $script:Config.RepoPath

    if ((Get-Date) - $startTime -gt $timeout) {
      throw 'Paste timeout exceeded (5 minutes)'
    }

    try {
      $line = Read-Host
      if ($line -eq 'END'){ break }
      $lines.Add($line)

      if ($lines.Count -gt 10000) {
        throw 'Too many lines pasted (limit: 10000). Use -From parameter for large files.'
      }
    } catch {
      throw "Error reading input: $($_.Exception.Message)"
    }
  }

  return ($lines -join "`n")
}

# -------------------------
# Prompt inventory + index
# -------------------------
function Initialize-DomainFolder([string]$repoRoot){
  $root = Join-Path $repoRoot "prompts"
  New-RepoDirectory $root
  foreach($d in @("strategy","coding","ops","trading")){
    New-RepoDirectory (Join-Path $root $d)
  }
}

function Get-PromptsInventory([string]$repoRoot){
  $promptsRoot = Join-Path $repoRoot "prompts"
  New-RepoDirectory $promptsRoot
  $items = @()

  try {
    $files = Get-ChildItem -Path $promptsRoot -Recurse -File -Filter "*.md" -ErrorAction SilentlyContinue
  } catch {
    Write-Warn "Error scanning prompts directory: $($_.Exception.Message)"
    return @()
  }

  foreach($f in $files){
    if ($f.Name -ieq "README.md") { continue }

    try {
      $pattern = '^(STR|COD|OPS|TRD)__([a-z0-9_]+)__v(\d+\.\d+(?:\.\d+)?)\.md$'
      $regex = [regex]::new($pattern, "IgnoreCase", [TimeSpan]::FromMilliseconds(100))
      $m = $regex.Match($f.Name)

      if (-not $m.Success) {
        Write-Warn "Skipping No-standard prompt file: $($f.Name)"
        continue
      }

      $prefix = $m.Groups[1].Value.ToUpperInvariant()
      $slug = $m.Groups[2].Value.ToLowerInvariant()
      $verStr = $m.Groups[3].Value

      if ($slug -match '\.\.') {
        Write-Warn "Skipping suspicious slug in file: $($f.Name)"
        continue
      }

      $dom = switch($prefix){
        "STR"{"strategy"}
        "COD"{"coding"}
        "OPS"{"ops"}
        "TRD"{"trading"}
        default{
          Write-Warn "Unknown prefix in file: $($f.Name)"
          ""
        }
      }

      if ([string]::IsNullOrEmpty($dom)) { continue }

      $items += [pscustomobject]@{
        Domain = $dom
        Prefix = $prefix
        Slug = $slug
        Version = (ConvertTo-Version $verStr)
        VersionText = $verStr
        Path = $f.FullName
        RelPath = $f.FullName.Substring($repoRoot.Length).TrimStart("\","/")
        LastWriteTime = $f.LastWriteTime
        SizeKB = [math]::Round($f.Length / 1KB, 2)
      }
    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
      Write-Warn "Regex timeout on file: $($f.Name) - skipping"
      continue
    } catch {
      Write-Warn "Error processing file $($f.Name): $($_.Exception.Message)"
      continue
    }
  }

  return $items
}

function Get-LatestPrompt([object[]]$inv, [string]$domain, [string]$slug){
  $promptMatches = $inv | Where-Object { $_.Slug -eq $slug -and $_.Domain -eq $domain }
  if (-not $promptMatches) { return $null }
  return ($promptMatches | Sort-Object Version -Descending | Select-Object -First 1)
}

function Build-Index([string]$repoRoot, [object[]]$inv){
  $indexPath = Join-Path $repoRoot "prompts\_index.md"

  $latest = $inv | Group-Object Domain,Slug | ForEach-Object {
    $_.Group | Sort-Object Version -Descending | Select-Object -First 1
  } | Sort-Object Domain,Slug

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Prompts & Code Index")
  $lines.Add("")
  $lines.Add(("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
  $totalPrompts = @($latest).Count
  $lines.Add(("Total prompts: {0}" -f $totalPrompts))
  $lines.Add("")

  $currentDomain = ""
  foreach($p in $latest){
    if ($p.Domain -ne $currentDomain){
      $currentDomain = $p.Domain
      $lines.Add(("## {0}" -f $currentDomain))
      $lines.Add("")
      $lines.Add("| Slug | Version | Size | Last Modified | File |")
      $lines.Add("|---|---:|---:|---|---|")
    }
    $rel = $p.RelPath.Replace("\","/")
    $lastMod = $p.LastWriteTime.ToString("yyyy-MM-dd")
    $lines.Add(("| {0} | {1} | {2} KB | {3} | ``{4}`` |" -f $p.Slug, (Format-Version $p.Version), $p.SizeKB, $lastMod, $rel))
  }

  $lines.Add("")
  $lines.Add("## [TOOL] Code Projects & Scripts")
  $lines.Add("")
  $lines.Add("| Type | File | Size | Last Modified |")
  $lines.Add("|---|---|---:|---|")

  $codeFiles = Get-ChildItem -Path $repoRoot -Recurse -File -Include "*.ps1","*.py","*.vbs","*.bas","*.xlsm" |
    Where-Object { $_.FullName -notlike "*\.backup*" -and $_.FullName -notlike "*\.git*" }

  foreach($f in ($codeFiles | Sort-Object Extension, Name)){
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart("\","/").Replace("\","/")
    $type = switch($f.Extension.ToLower()){
      ".ps1" { "PowerShell" }
      ".py"  { "Python" }
      ".vbs" { "VBScript" }
      ".bas" { "VBA Module" }
      ".xlsm" { "Excel Macro" }
      default { $f.Extension }
    }
    $sizeKB = [math]::Round($f.Length / 1KB, 2)
    $lastMod = $f.LastWriteTime.ToString("yyyy-MM-dd")
    $lines.Add(("| {0} | ``{1}`` | {2} KB | {3} |" -f $type, $rel, $sizeKB, $lastMod))
  }

  $lines.Add("")
  $lines.Add("---")
  $lines.Add("*Generated by promptlab.ps1 v3.3 (corporate edition)*")

  Set-TextFile $indexPath ($lines -join "`n")
  return $indexPath
}

function Select-PromptInteractive([object[]]$promptMatches){
  $i = 1
  foreach($m in ($promptMatches | Sort-Object Version -Descending)){
    Write-Host ("[{0}] {1}  v{2}  ({3} KB)" -f $i, $m.RelPath, (Format-Version $m.Version), $m.SizeKB)
    $i++
  }

  $pick = Read-Host "Sélection (1-$($promptMatches.Count))"
  $n = 0
  if (-not [int]::TryParse($pick, [ref]$n)) { throw "Sélection invalide." }
  if ($n -lt 1 -or $n -gt $promptMatches.Count) { throw "Sélection hors limites." }
  return (($promptMatches | Sort-Object Version -Descending)[$n-1])
}

function Resolve-TargetPromptPath {
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][object[]]$inv,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$slug,
    [Parameter()][string]$explicitPath
  )

  if (-not [string]::IsNullOrWhiteSpace($explicitPath)){
    $full = if ([System.IO.Path]::IsPathRooted($explicitPath)) {
      $explicitPath
    } else {
      Join-Path $repoRoot $explicitPath
    }

    $fullNormalized = [System.IO.Path]::GetFullPath($full)
    if (-not $fullNormalized.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Security: Explicit path outside repo: $fullNormalized"
    }

    return [pscustomobject]@{ Mode="explicit"; Target=$full; Existing=$null }
  }

  # ✅ FIX: Forcer un tableau vide et vérifier avant .Count
  $promptMatches = @()
  if ($inv -and $inv.Count -gt 0) {
    $temp = @($inv | Where-Object { $_.Slug -eq $slug -and $_.Domain -eq $domain } | Sort-Object Version -Descending)
    if ($temp) {
      $promptMatches = $temp
    }
  }

  if (-not $promptMatches -or $promptMatches.Count -eq 0){
    $v = if([string]::IsNullOrWhiteSpace($Version)) { [version]"0.1.0" } else { ConvertTo-Version $Version }
    $prefix = Get-DomainPrefix $domain
    $file = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $v))
    $target = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $file)
    return [pscustomobject]@{ Mode="new"; Target=$target; Existing=$null }
  }

  if ($promptMatches.Count -eq 1){
    return [pscustomobject]@{ Mode="existing"; Target=$promptMatches[0].Path; Existing=$promptMatches[0] }
  }

  if ($Yes){
    return [pscustomobject]@{ Mode="existing"; Target=$promptMatches[0].Path; Existing=$promptMatches[0] }
  }

  Write-Box "Plusieurs versions trouvées" @("Sélectionne le prompt à remplacer:")
  $pick = Select-PromptInteractive $promptMatches
  return [pscustomobject]@{ Mode="existing"; Target=$pick.Path; Existing=$pick }
}



# -------------------------
# README handling
# -------------------------
function Format-ReadmeUserText([string]$text, [string]$promptTitle){
  $t = $text.Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { throw "README vide." }
  if (Test-IsMarkdown $t) { return $t }

  $out = New-Object System.Collections.Generic.List[string]
  $out.Add("# $promptTitle - README")
  $out.Add("")
  $lines = $t -split "`r?`n"
  foreach($ln in $lines){
    $l = $ln.TrimEnd()
    if ($l -match '^\s*$'){ $out.Add("") ; continue }
    if ($l -match '^\s*[-\*]\s+') { $out.Add($l.Trim()) ; continue }
    if ($l -match '^\s*\d+\.\s+') { $out.Add($l.Trim()) ; continue }
    if ($l -match '^\s*[A-Z0-9 _\-]{3,}\s*:\s*.+$'){
      $parts = $l.Split(":",2)
      $out.Add("**$($parts[0].Trim())**: $($parts[1].Trim())")
      continue
    }
    $out.Add($l)
  }
  return ($out -join "`n")
}

function Update-Readme {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$slug,
    [Parameter(Mandatory)][string]$promptRelPath,
    [Parameter(Mandatory)][string]$promptTitle,
    [Parameter(Mandatory)][string]$userReadmeText,
    [Parameter(Mandatory)][string]$scope,
    [Parameter(Mandatory)][string]$mode
  )

  $formatted = Format-ReadmeUserText -text $userReadmeText -promptTitle $promptTitle
  if ($NormalizeEol){ $formatted = ConvertTo-LfEol $formatted }

  if ($scope -eq "prompt"){
    $folder = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $slug)
    New-RepoDirectory $folder
    $target = Join-Path $folder "README.md"
    if (Test-Path $target){ Copy-FileBackup $repoRoot $target | Out-Null }
    $ref = "`n`n---`n`n**Prompt file**: ``$($promptRelPath)```n"
    if ($formatted -notmatch '(?m)^\*\*Prompt file\*\*:'){
      $formatted = $formatted + $ref
    }
    Set-TextFile $target $formatted
    return $target
  }

  $target = if ($scope -eq "domain") {
    $folder = Join-Path $repoRoot ("prompts\{0}" -f $domain)
    New-RepoDirectory $folder
    Join-Path $folder "README.md"
  } else {
    Join-Path $repoRoot "README.md"
  }

  if (Test-Path $target){ Copy-FileBackup $repoRoot $target | Out-Null }

  if ($mode -eq "replace"){
    Set-TextFile $target $formatted
    return $target
  }

  $safeSlug = $slug -replace '[^a-zA-Z0-9_]', ''
  $start = ("<!-- PROMPTLAB:{0}:START -->" -f $safeSlug.ToUpperInvariant())
  $end   = ("<!-- PROMPTLAB:{0}:END -->" -f $safeSlug.ToUpperInvariant())
  $block = @(
    $start,
    "",
    $formatted,
    "",
    ("**Prompt file**: ``$($promptRelPath)``"),
    "",
    $end
  ) -join "`n"

  $existing = ""
  if (Test-Path $target){ $existing = Read-TextFromFile $target }
  if ([string]::IsNullOrWhiteSpace($existing)){
    Set-TextFile $target $block
    return $target
  }

  if ($existing -like "*$start*"){
    try {
      $pattern = [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
      $regex = [regex]::new($pattern, "Singleline", [TimeSpan]::FromSeconds(1))
      $new = $regex.Replace($existing, $block)
      Set-TextFile $target $new
    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
      throw 'Timeout processing README markers - file may be too large or corrupted'
    }
    return $target
  }

  Set-TextFile $target ($existing.TrimEnd() + "`n`n" + $block + "`n")
  return $target
}

# -------------------------
# Git operations - SECURITY ENHANCED
# -------------------------
function Invoke-Git([string]$repoRoot, [string]$gitArgs){
  if (-not (Test-GitInstalled)) { throw "Git not installed" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "git"
  $psi.Arguments = $gitArgs
  $psi.WorkingDirectory = $repoRoot
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  try {
    [void]$p.Start()

    $timeout = [TimeSpan]::FromSeconds(30)
    if (-not $p.WaitForExit($timeout.TotalMilliseconds)) {
      $p.Kill()
      throw "Git command timeout after 30 seconds: $gitArgs"
    }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    return [pscustomobject]@{ Code=$p.ExitCode; Out=$stdout.Trim(); Err=$stderr.Trim() }
  } catch {
    if (-not $p.HasExited) { $p.Kill() }
    throw "Git command failed: $($_.Exception.Message)"
  } finally {
    $p.Dispose()
  }
}

function Get-CurrentGitBranch([string]$repoRoot) {
  $result = Invoke-Git $repoRoot "branch --show-current"
  if ($result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Out)) {
    $result = Invoke-Git $repoRoot "rev-parse --abbrev-ref HEAD"
    if ($result.Code -ne 0) {
      throw "Unable to determine current branch"
    }
  }
  return $result.Out.Trim()
}

function Confirm-GitIdentity {
  $name = (git config --global user.name 2>$null)
  $email = (git config --global user.email 2>$null)
  if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)){
    throw 'Identité Git manquante. Fix: git config --global user.name "Nom" ; git config --global user.email "you@example.com"'
  }
}

function Set-GitRemoteOrigin {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter()][string]$repoName,
    [Parameter()][string]$suggestedOwner
  )

  $name = if ($repoName) { $repoName } else { Split-Path $repoRoot -Leaf }
  $owner = if ($suggestedOwner) { $suggestedOwner } else { "user" }
  $ownerInput = Read-Host "Git owner/user [$owner]"
  if (-not [string]::IsNullOrWhiteSpace($ownerInput)) { $owner = $ownerInput }

  Write-Host ""
  Write-Host "Remote type:" -ForegroundColor Yellow
  Write-Host "[1] GitHub HTTPS" -ForegroundColor Cyan
  Write-Host "[2] GitHub SSH" -ForegroundColor Cyan
  Write-Host "[3] Custom URL" -ForegroundColor Cyan
  $typeChoice = Read-Host "Choix (1-3)"

  $url = switch ($typeChoice) {
    "1" { "https://github.com/$owner/$name.git" }
    "2" { "git@github.com:$owner/$name.git" }
    "3" { Read-Host "Remote URL" }
    default { "https://github.com/$owner/$name.git" }
  }

  if ([string]::IsNullOrWhiteSpace($url)) { throw "Remote URL vide." }

  if ($PSCmdlet.ShouldProcess($repoRoot, "Add remote origin ($url)")) {
    Push-Location $repoRoot
    try {
      & git remote add origin $url 2>$null | Out-Null
    } finally {
      Pop-Location
    }
  }

  Write-Ok "Remote ajouté: $url"
}


# =====================================================
# Test-GitDoctor ENHANCED - Version 2.1
# Avec gestion automatique LF/CRLF et auto-fix complet
# =====================================================

function Read-YesNo([string]$prompt) {
  $answer = Read-Host "$prompt"
  return ($answer.ToLowerInvariant() -eq 'y')
}

function Test-GitDoctor([string]$repoRoot){
  $issues = @()
  $fixed = @()

  Write-Box "PROMPT-LAB Doctor" @("Diagnostic en cours...")

  # ========================================
  # CHECK 1: Git installé
  # ========================================
  if (-not (Test-GitInstalled)){
    $issues += "Git No installé"
    Write-Warn "❌ Git n'est pas installé"
    Write-Host "   📥 Télécharge: https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host "   ⚠️  Mode 'pack ZIP' disponible comme alternative" -ForegroundColor Yellow
    return
  }
  Write-Ok "[OK] Git installé"

  # ========================================
  # CHECK 1.5: Configuration Git autocrlf (NOUVEAU)
  # ========================================
  try {
    Push-Location $repoRoot
    $autocrlf = & git config core.autocrlf 2>$null
    Pop-Location

    if ($autocrlf -ne "true") {
      Write-Warn "⚠️  Git autocrlf No configuré (peut causer des problèmes LF/CRLF)"

      if ($Yes -or (Read-YesNo "   🔧 Configurer autocrlf=true? (Y/N)")) {
        try {
          & git config --global core.autocrlf true
          Write-Ok "   [OK] Git autocrlf configuré"
          $fixed += "Git autocrlf"
        } catch {
          Write-Warn "   ⚠️  Unable to configurer autocrlf"
        }
      }
    } else {
      Write-Ok "[OK] Git autocrlf configuré"
    }
  } catch {
    Write-Warn "⚠️  Unable to vérifier autocrlf"
  }

  # ========================================
  # CHECK 2: Repo Git initialisé
  # ========================================
  $gitInitialized = $false
  try {
    Push-Location $repoRoot
    $testResult = & git rev-parse --is-inside-work-tree 2>$null
    $exitCode = $LASTEXITCODE
    Pop-Location
    $gitInitialized = ($exitCode -eq 0 -and $testResult -eq "true")
  } catch {
    $gitInitialized = $false
  }

  if (-not $gitInitialized) {
    $issues += "Repo No initialisé"
    Write-Warn "❌ Pas de repo Git détecté dans: $repoRoot"

    if ($Yes -or (Read-YesNo "   🔧 Initialiser Git maintenant? (Y/N)")) {
      try {
        Push-Location $repoRoot
        $iniAllput = & git init 2>&1
        $initExitCode = $LASTEXITCODE
        Pop-Location

        if ($initExitCode -eq 0) {
          Write-Ok "   [OK] Git initialisé"
          $fixed += "Git init"

          # Créer .gitignore
          $gitignorePath = Join-Path $repoRoot ".gitignore"
          if (-not (Test-Path $gitignorePath)) {
            $gitignore = @"
# Prompt-Lab
.backup/
dist/
*.tmp
*.bak
.DS_Store
Thumbs.db
"@
            Set-Content $gitignorePath $gitignore -Encoding UTF8
            Write-Info "   [OK] .gitignore créé"
          }

          # Configurer branche par défaut
          try {
            Push-Location $repoRoot
            & git config init.defaultBranch main 2>&1 | Out-Null
            Pop-Location
          } catch {
            Write-Verbose "Failed to set git init.defaultBranch: $($_.Exception.Message)"
          }

          # Refresh status
          $gitInitialized = $true

        } else {
          Write-Fail "   ✗ Échec init: $iniAllput"
        }
      } catch {
        Write-Fail "   ✗ Erreur: $($_.Exception.Message)"
      }
    } else {
      Write-Info "   💡 Manuel: cd '$repoRoot' puis exécute 'git init'"
    }
  } else {
    Write-Ok "[OK] Repo Git valide"
  }

  # ========================================
  # CHECK 3: Structure prompts/
  # ========================================
  $promptsDir = Join-Path $repoRoot "prompts"
  if (-not (Test-Path $promptsDir)) {
    $issues += "Dossier prompts/ manquant"
    Write-Warn "❌ Structure prompts/ absente"

    if ($Yes -or (Read-YesNo "   🔧 Créer l'arborescence prompts/? (Y/N)")) {
      try {
        Initialize-DomainFolder $repoRoot
        Write-Ok "   [OK] Dossiers créés: prompts/{strategy,coding,ops,trading}"
        $fixed += "Structure prompts/"
      } catch {
        Write-Fail "   ✗ Échec création: $($_.Exception.Message)"
      }
    } else {
      Write-Info "   💡 Manuel: mkdir prompts\strategy,prompts\coding,prompts\ops,prompts\trading"
    }
  } else {
    Write-Ok "[OK] Structure prompts/ présente"

    # Vérifier sous-dossiers
    $missing = @()
    foreach($d in @("strategy","coding","ops","trading")){
      if (-not (Test-Path (Join-Path $promptsDir $d))) {
        $missing += $d
      }
    }
    if ($missing) {
      $issues += "Sous-dossiers manquants: $($missing -join ', ')"
      Write-Warn "⚠️  Sous-dossiers manquants: $($missing -join ', ')"

      if ($Yes -or (Read-YesNo "   🔧 Créer les dossiers manquants? (Y/N)")) {
        foreach($d in $missing) {
          New-Item -ItemType Directory -Path (Join-Path $promptsDir $d) -Force | Out-Null
        }
        Write-Ok "   [OK] Sous-dossiers créés: $($missing -join ', ')"
        $fixed += "Sous-dossiers"
      }
    }
  }

  # ========================================
  # CHECK 4: Identité Git
  # ========================================
  try {
    $name = & git config --global user.name 2>$null
    $email = & git config --global user.email 2>$null

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)){
      $issues += "Identité Git No configurée"
      Write-Warn "❌ Identité Git manquante"

      if ($Yes -or (Read-YesNo "   🔧 Configurer maintenant? (Y/N)")) {
        $userName = Read-Host "   👤 Nom complet (ex: Jean Dupont)"
        $userEmail = Read-Host "   📧 Email (ex: jean@example.com)"

        if (-not [string]::IsNullOrWhiteSpace($userName) -and -not [string]::IsNullOrWhiteSpace($userEmail)) {
          & git config --global user.name "$userName"
          & git config --global user.email "$userEmail"
          Write-Ok "   [OK] Identité configurée: $userName <$userEmail>"
          $fixed += "Git identity"
        } else {
          Write-Warn "   ⚠️  Identité No configurée (champs vides)"
        }
      } else {
        Write-Host "   💡 Manuel: git config --global user.name 'Ton Nom'" -ForegroundColor Cyan
        Write-Host "              git config --global user.email 'ton@email.com'" -ForegroundColor Cyan
      }
    } else {
      Write-Ok "[OK] Identité Git: $name <$email>"
    }
  } catch {
    Write-Warn "⚠️  Unable to vérifier l'identité Git"
  }

  # ========================================
  # CHECK 5: Branche actuelle
  # ========================================
  if ($gitInitialized) {
    try {
      Push-Location $repoRoot
      $branch = & git branch --show-current 2>$null
      $branchExitCode = $LASTEXITCODE
      Pop-Location

      if ($branchExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
        Write-Ok "[OK] Branche active: $branch"
      } else {
        Write-Warn "⚠️  Noee branche active (normal si repo vide - fais un premier commit)"
      }
    } catch {
      Write-Warn "⚠️  Unable to détecter la branche"
    }
  }

  # ========================================
  # CHECK 6: Remote configuré
  # ========================================
  if ($gitInitialized) {
    try {
      Push-Location $repoRoot
      $remote = & git remote -v 2>$null
      $remoteExitCode = $LASTEXITCODE
      Pop-Location

      if ($remoteExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remote)) {
        Write-Ok "[OK] Remote configuré:"
        $remote -split "`n" | Select-Object -First 2 | ForEach-Object {
          Write-Host "     $_" -ForegroundColor DarkGray
        }
      } else {
        Write-Warn "⚠️  Noe remote GitHub/GitLab configuré (local seulement)"
        Write-Host "   💡 Pour ajouter: git remote add origin <URL>" -ForegroundColor Cyan
        if ($Yes -or (Read-YesNo "   🔧 Configurer origin maintenant? (Y/N)")) {
          $email = & git config --global user.email 2>$null
          $suggestedOwner = $null
          if ($email -match '^([^@]+)@') { $suggestedOwner = $matches[1] }
          $repoName = if ($script:Config -and $script:Config.RepoName) { $script:Config.RepoName } else { Split-Path $repoRoot -Leaf }

          if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) {
            if (Read-YesNo "   🔧 Utiliser RepoUrl ($RepoUrl) ? (Y/N)") {
              & git remote add origin $RepoUrl 2>$null | Out-Null
              Write-Ok "   [OK] Remote ajouté: $RepoUrl"
            } else {
              Set-GitRemoteOrigin -repoRoot $repoRoot -repoName $repoName -suggestedOwner $suggestedOwner
            }
          } else {
            Set-GitRemoteOrigin -repoRoot $repoRoot -repoName $repoName -suggestedOwner $suggestedOwner
          }
        }
      }
    } catch {
      Write-Warn "⚠️  Unable to vérifier remote"
    }
  }


# ========================================
# CHECK 7: Etat du repo
# ========================================
if ($gitInitialized) {
  try {
    $statusResult = Invoke-Git $repoRoot "status --porcelain"
    if ($statusResult.Code -eq 0) {
      if ([string]::IsNullOrWhiteSpace($statusResult.Out)) {
        Write-Ok "[OK] Repo clean (no uncommitted changes)"
      } else {
        $fileCount = @($statusResult.Out -split "`n" | Where-Object { $_ }).Count
        Write-Warn ("??  Repo dirty: {0} file(s) modified" -f $fileCount)

        if ($Yes -or (Read-YesNo "   ?? Create an initial commit? (Y/N)")) {
          try {
            Push-Location $repoRoot
            & git add . 2>&1 | Out-Null
            $commitMsg = "chore: initial prompt-lab setup"
            $null = & git -c core.safecrlf=false commit -m "$commitMsg" 2>&1
            $commitExitCode = $LASTEXITCODE
            Pop-Location
            if ($commitExitCode -eq 0) {
              Write-Ok "   [OK] Initial commit created"
              $fixed += "Initial commit"
            } else {
              Write-Fail "   ? Commit failed"
              Write-Info "   ?? Try: git add . && git -c core.safecrlf=false commit -m init"
            }
          } catch {
            try { Pop-Location } catch { Write-Verbose ("Pop-Location failed: {0}" -f $_.Exception.Message) }
            Write-Fail ("   ? Error: {0}" -f $_.Exception.Message)
          }
        }
      }
    } else {
      $errText = if ([string]::IsNullOrWhiteSpace($statusResult.Err)) { "unknown error" } else { $statusResult.Err }
      Write-Warn ("??  Unable to verify repo status: {0}" -f $errText)
    }
  } catch {
    Write-Warn ("??  Unable to verify repo status: {0}" -f $_.Exception.Message)
  }
}
# ========================================
# CHECK 8: README.md existe
# ========================================
  $readmePath = Join-Path $repoRoot "README.md"
  if (-not (Test-Path $readmePath)) {
    $issues += "README.md manquant"
    Write-Warn "⚠️  README.md absent"

    if ($Yes -or (Read-YesNo "   🔧 Créer un README de base? (Y/N)")) {
      $readme = @"
# Prompt Lab

Repository de prompts versionnés géré par **promptlab.ps1**.

## Structure

``````
prompts/
├── strategy/     # Prompts stratégiques
├── coding/       # Prompts de code
├── ops/          # Prompts opérationnels
└── trading/      # Prompts trading
``````

## Usage

``````powershell
# Mode interactif
.\promptlab.ps1

# Créer un prompt
.\promptlab.ps1 new -Domain trading -Name ma_strategie -Version 1.0.0

# Doctor (vérification)
.\promptlab.ps1 doctor
``````

## Index

Voir [prompts/_index.md](prompts/_index.md) pour la liste complète.

---
Généré par promptlab.ps1 v2.1
"@
      try {
        Set-Content $readmePath $readme -Encoding UTF8
        Write-Ok "   [OK] README.md créé"
        $fixed += "README.md"
      } catch {
        Write-Fail "   ✗ Échec création README: $($_.Exception.Message)"
      }
    }
  } else {
    Write-Ok "[OK] README.md présent"
  }

  # ========================================
  # CHECK 9: Index prompts
  # ========================================
  $indexPath = Join-Path $repoRoot "prompts\_index.md"
  if (-not (Test-Path $indexPath)) {
    Write-Warn "⚠️  Index prompts manquant"

    if ($Yes -or (Read-YesNo "   🔧 Générer l'index? (Y/N)")) {
      try {
        $inv = Get-PromptsInventory $repoRoot
        Build-Index $repoRoot $inv | Out-Null
        Write-Ok "   [OK] Index généré"
        $fixed += "Index"
      } catch {
        Write-Fail "   ✗ Échec génération index: $($_.Exception.Message)"
      }
    }
  } else {
    Write-Ok "[OK] Index prompts présent"
  }

  # ========================================
  # RÉSUMÉ FINAL
  # ========================================
  Write-Host ""
  Write-Box "RÉSUMÉ" @(
    "Issues détectées: $($issues.Count)",
    "Issues corrigées: $($fixed.Count)"
  )

  if ($issues.Count -eq 0) {
    Write-Host "🎉 " -NoNewline -ForegroundColor Green
    Write-Host "Environnement parfaitement configuré !" -ForegroundColor Green
    Write-Host ""
    Write-Host "Prochaines étapes:" -ForegroundColor Cyan
    Write-Host "  1. Crée ton premier prompt: " -NoNewline
    Write-Host ".\promptlab.ps1 new -Domain trading -Name test -Version 1.0.0" -ForegroundColor Yellow
    Write-Host "  2. Push vers GitHub: " -NoNewline
    Write-Host "git push origin main" -ForegroundColor Yellow
  } elseif ($fixed.Count -eq $issues.Count) {
    Write-Host "✅ " -NoNewline -ForegroundColor Green
    Write-Host "Alles les issues ont été corrigées !" -ForegroundColor Green
    Write-Host "Corrections: " -NoNewline -ForegroundColor DarkGray
    Write-Host ($fixed -join ', ') -ForegroundColor White
  } elseif ($fixed.Count -gt 0) {
    Write-Host "⚠️  " -NoNewline -ForegroundColor Yellow
    Write-Host "Corrections partielles appliquées" -ForegroundColor Yellow
    Write-Host "Corrigées: " -NoNewline -ForegroundColor DarkGray
    Write-Host ($fixed -join ', ') -ForegroundColor White
    $remaining = $issues | Where-Object { $_ -notin $fixed }
    if ($remaining) {
      Write-Host "Restantes: " -NoNewline -ForegroundColor DarkGray
      Write-Host ($remaining -join ', ') -ForegroundColor Yellow
    }
  } else {
    Write-Host "❌ " -NoNewline -ForegroundColor Red
    Write-Host "Issues No résolues: " -NoNewline -ForegroundColor Red
    Write-Host ($issues -join ', ')
    Write-Host ""
    Write-Host "💡 Relance 'doctor' pour corriger interactivement" -ForegroundColor Cyan
  }

  Write-Host ""
}



function Invoke-GitCommitPush {
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string[]]$pathsToStage,
    [Parameter(Mandatory)][string]$message
  )

  if (-not (Test-GitInstalled)){ throw "Git No installé." }
  Confirm-GitIdentity

  if ([string]::IsNullOrWhiteSpace($message)) {
    throw "Commit message cannot be empty"
  }
  $message = $message -replace '[`$;|&<>]', ''

  Push-Location $repoRoot
  try {
    foreach($p in $pathsToStage | Select-Object -Unique){
      $rel = $p
      if ($p.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)){
        $rel = $p.Substring($repoRoot.Length).TrimStart("\","/")
      }

      $relGit = $rel -replace '\\', '/'

      Write-Host "[DEBUG] Adding: $relGit" -ForegroundColor DarkGray

      # ✅ VERSION ULTRA-ROBUSTE : Ignore TOUS les warnings
      $ErrorActionPreference = 'SilentlyContinue'
      $null = & git add -- $relGit 2>&1
      $ErrorActionPreference = 'Stop'

      Write-Host "[DEBUG] Added: $relGit" -ForegroundColor Green
    }

    Write-Host "[DEBUG] Committing..." -ForegroundColor DarkGray

    $ErrorActionPreference = 'SilentlyContinue'
    & git commit -m $message 2>&1 | Out-Null
    $commitExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($commitExitCode -ne 0) {
      $status = & git status --porcelain 2>&1
      if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Host "[Info] Nothing to commit" -ForegroundColor Yellow
        Pop-Location
        return
      }
      Pop-Location
      throw "git commit failed"
    }

    Write-Ok "Committed: $message"

    $branch = & git branch --show-current 2>&1
    if ([string]::IsNullOrWhiteSpace($branch)) {
      $branch = "main"
    }

    Write-Host "[DEBUG] Pushing to $branch..." -ForegroundColor DarkGray

    $ErrorActionPreference = 'SilentlyContinue'
    & git push origin $branch 2>&1 | Out-Null
    $pushExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($pushExitCode -ne 0) {
      Pop-Location
      throw "git push failed"
    }

    Write-Ok "Pushed to origin/$branch"

  } finally {
    Pop-Location
  }
}







# -------------------------
# Pack upload-ready
# -------------------------
function New-UploadInstruction {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$outPath, [string]$repoUrl)
  $repoLabel = if([string]::IsNullOrWhiteSpace($repoUrl)){"(ton repo GitHub)"} else {$repoUrl}
  $txt = @"
# Upload GitHub (sans Git local)

## Method 1: GitHub Web UI

1) Ouvre ton repo GitHub: $repoLabel
2) Clique **Add file** → **Upload files**
3) Dézippe puis glisse-dépose le contenu du ZIP (garder l'arborescence):
   - prompts/
   - README.md (si présent)
4) Message de commit: ``promptlab: update prompts``
5) Branch: ``main`` (ou ta branch active)
6) Clique **Commit changes**

## Method 2: GitHub CLI (si installé)

``````bash
gh repo sync
unzip promptlab_upload_*.zip -d .
git add prompts README.md
git commit -m "promptlab: update prompts"
git push origin main
``````

## Verify Upload

After upload, check:
- [OK] prompts/_index.md is updated
- [OK] Version numbers are correct
- [OK] README links work

---
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@
  Set-TextFile $outPath $txt.TrimEnd()
}

function New-PromptLabPack {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$repoRoot)
  $dist = Join-Path $repoRoot "dist"
  New-RepoDirectory $dist
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $instructions = Join-Path $dist "UPLOAD_INSTRUCTIONS.md"
  New-UploadInstruction $instructions $RepoUrl
  $zip = Join-Path $dist ("promptlab_upload_{0}.zip" -f $ts)

  $items = @()
  $prompts = Join-Path $repoRoot "prompts"
  if (Test-Path $prompts){ $items += $prompts }
  $rootReadme = Join-Path $repoRoot "README.md"
  if (Test-Path $rootReadme){ $items += $rootReadme }
  $items += $instructions

  if ($DryRun -or -not $PSCmdlet.ShouldProcess($zip, "Create pack")){
    Write-Info "DRY-RUN: would create zip: $zip"
    return $zip
  }

  if (Test-Path $zip){ Remove-Item $zip -Force }

  try {
    Compress-Archive -Path $items -DestinationPath $zip -Force -CompressionLevel Optimal
    $zipSize = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Write-Ok "Pack created: $zip ($zipSize MB)"
  } catch {
    throw "Failed to create pack: $($_.Exception.Message)"
  }

  return $zip
}

function Get-GitMode([string]$repoRoot){
  if (Test-GitInstalled){ return "git" }

  Write-Box "Git No détecté" @(
    "Option 1 (recommandé): Générer un ZIP 'upload-ready' + instructions GitHub web.",
    "Option 2: Cancel."
  )
  $choice = if($Yes){"1"} else { Read-Host "Choisis (1/2)" }
  if ($choice -ne "1"){ throw "Annulé." }

  New-PromptLabPack $repoRoot | Out-Null
  Write-Info "Upload: ouvre dist/UPLOAD_INSTRUCTIONS.md"
  return "pack"
}

# -------------------------
# Core actions
# -------------------------
function Set-PromptContent {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter()][string]$fromPath,
    [Parameter()][switch]$doReadme,
    [Parameter()][switch]$Force,
    [Parameter()][switch]$Yes
  )

  Initialize-DomainFolder $repoRoot
  $slug = ConvertTo-Slug $name
  $inv = Get-PromptsInventory $repoRoot

  $resolved = Resolve-TargetPromptPath -repoRoot $repoRoot -inv $inv -domain $domain -slug $slug -explicitPath $Path
  $target = $resolved.Target

  $content = if (-not [string]::IsNullOrWhiteSpace($fromPath)) {
    Read-TextFromFile $fromPath
  } else {
    Read-TextFromPaste "PROMPT ($domain/$slug)"
  }

  if ([string]::IsNullOrWhiteSpace($content)) { throw "Contenu prompt vide." }

  if ($content.Length -gt 5MB) {
    throw "Prompt content too large (>5MB). Split into multiple prompts."
  }

  if (-not (Test-IsMarkdown $content)){
    $content = Convert-ToMarkdownSafe -text $content -title ("{0}/{1} (converted)" -f $domain, $slug)
  }

  if ((Test-Path $target) -and -not $Force -and -not $Yes){
    Write-Warn "Le fichier cible existe: $target"
    if (-not $PSCmdlet.ShouldContinue($target, "Remplacer fichier existant?")) {
      throw "Annulé par l'utilisateur."
    }
  }

  Copy-FileBackup $repoRoot $target | Out-Null
  Set-TextFile $target $content
  Write-Ok ("Prompt écrit: " + $target)

  $inv2 = Get-PromptsInventory $repoRoot
  $index = Build-Index $repoRoot $inv2
  Write-Ok ("Index MAJ: " + $index)

  $changed = @($target, $index)

  if ($Readme){ $doReadme = $true }

  if ($doReadme){
    $readmeText = if (-not [string]::IsNullOrWhiteSpace($ReadmeFrom)) {
      Read-TextFromFile $ReadmeFrom
    } else {
      Read-TextFromPaste "README ($ReadmeScope)"
    }

    $promptRel = $target.Substring($repoRoot.Length).TrimStart("\","/").Replace("\","/")
    $promptTitle = "$domain/$slug"
    $readmeTarget = Update-Readme -repoRoot $repoRoot -domain $domain -slug $slug `
      -promptRelPath $promptRel -promptTitle $promptTitle -userReadmeText $readmeText `
      -scope $ReadmeScope -mode $ReadmeMode
    Write-Ok ("README MAJ: " + $readmeTarget)
    $changed += $readmeTarget
  }

  return [pscustomobject]@{
    TargetPrompt = $target
    IndexPath = $index
    ChangedPaths = ($changed | Select-Object -Unique)
    Slug = $slug
  }
}

function New-PromptOnly {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$version
  )

  Initialize-DomainFolder $repoRoot
  $slug = ConvertTo-Slug $name
  $inv = Get-PromptsInventory $repoRoot

  if (Get-LatestPrompt -inv $inv -domain $domain -slug $slug){
    throw "Prompt existe déjà. Utilise 'up' ou 'sync'."
  }

  $prefix = Get-DomainPrefix $domain
  $v = ConvertTo-Version $version
  $file = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $v))
  $target = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $file)

  $content = Read-TextFromPaste "PROMPT NEW ($domain/$slug)"
  if ([string]::IsNullOrWhiteSpace($content)) { throw "Contenu prompt vide." }

  if (-not (Test-IsMarkdown $content)){
    $content = Convert-ToMarkdownSafe -text $content -title ("{0}/{1} (converted)" -f $domain, $slug)
  }

  if (-not $PSCmdlet.ShouldProcess($target, "Create new prompt")) {
    throw "Annulé par l'utilisateur."
  }

  Set-TextFile $target $content
  Write-Ok ("Prompt créé: " + $target)

  $inv2 = Get-PromptsInventory $repoRoot
  $index = Build-Index $repoRoot $inv2
  Write-Ok ("Index MAJ: " + $index)

  return [pscustomobject]@{
    TargetPrompt=$target
    IndexPath=$index
    ChangedPaths=@($target,$index)
    Slug=$slug
  }
}

function Update-PromptVersion {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$bump
  )

  $slug = ConvertTo-Slug $name
  $inv = Get-PromptsInventory $repoRoot
  $latest = Get-LatestPrompt -inv $inv -domain $domain -slug $slug
  if (-not $latest){ throw "Prompt introuvable pour bump: $domain/$slug" }

  $newV = Get-NextVersion $latest.Version $bump
  $prefix = Get-DomainPrefix $domain
  $newFile = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $newV))
  $dest = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $newFile)

  if ((Test-Path $dest) -and -not $Force){
    throw "Le fichier bump existe déjà: $dest (utilise -Force)."
  }

  if (-not $PSCmdlet.ShouldProcess($dest, "Bump version to $(Format-Version $newV)")) {
    throw "Annulé par l'utilisateur."
  }

  if ($DryRun){
    Write-Info "DRY-RUN: would copy $($latest.Path) -> $dest"
  } else {
    Copy-Item -Path $latest.Path -Destination $dest -Force
    Write-Ok "Version bumped: v$(Format-Version $latest.Version) → v$(Format-Version $newV)"
  }

  $inv2 = Get-PromptsInventory $repoRoot
  $index = Build-Index $repoRoot $inv2
  Write-Ok ("Index MAJ: " + $index)

  return [pscustomobject]@{
    TargetPrompt=$dest
    IndexPath=$index
    ChangedPaths=@($dest,$index)
    Slug=$slug
  }
}

function Restore-PromptVersion {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$toVersion
  )

  $slug = ConvertTo-Slug $name
  $inv = Get-PromptsInventory $repoRoot
  $targetVer = ConvertTo-Version $toVersion

  $match = $inv | Where-Object {
    $_.Slug -eq $slug -and
    $_.Domain -eq $domain -and
    $_.Version -eq $targetVer
  }

  if (-not $match) {
    Write-Fail "Version not found: $domain/$slug v$toVersion"
    $available = $inv | Where-Object { $_.Slug -eq $slug -and $_.Domain -eq $domain } |
      Sort-Object Version -Descending
    if ($available) {
      Write-Info "Available versions:"
      $available | ForEach-Object { Write-Host "  v$(Format-Version $_.Version)" }
    }
    throw "Rollback target not found"
  }

  $latest = Get-LatestPrompt -inv $inv -domain $domain -slug $slug
  if ($latest.Version -eq $targetVer) {
    Write-Warn "Already at version $toVersion"
    return
  }

  if (-not $PSCmdlet.ShouldProcess("$domain/$slug", "Rollback to v$toVersion")) {
    throw "Annulé par l'utilisateur."
  }

  $newV = Get-NextVersion $latest.Version "minor"
  $prefix = Get-DomainPrefix $domain
  $newFile = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $newV))
  $dest = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $newFile)

  Copy-Item -Path $match.Path -Destination $dest -Force

  $content = Get-Content $dest -Raw
  $notice = "`n`n---`n**ROLLBACK NOTICE**: This version is a rollback to v$(Format-Version $targetVer) from v$(Format-Version $latest.Version)`n"
  Set-Content $dest ($content + $notice)

  Write-Ok "Rolled back to v$toVersion (new version: v$(Format-Version $newV))"

  $inv2 = Get-PromptsInventory $repoRoot
  $index = Build-Index $repoRoot $inv2

  return [pscustomobject]@{
    TargetPrompt=$dest
    IndexPath=$index
    ChangedPaths=@($dest,$index)
    Slug=$slug
  }
}

# -------------------------
# Menu (TUI)
# -------------------------


# =====================================================
# MENU AMÉLIORÉ - Version Finale
# Remplace Menu-PickDomain et Invoke-Menu dans promptlab.ps1
# =====================================================



# =====================================================
# FIX COMPLET - AllES LES FONCTIONS
# Remplace Show-DomainPrompt ET Select-Prompt
# =====================================================

# -------------------------
# Fonction 1: Show-DomainPrompt (CORRIGÉE)
# -------------------------

function Show-DomainPrompt {
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [switch]$SyncFirst
  )

  if ($SyncFirst) {
    Write-Host ""
    Write-Host "🔄 Synchronisation avec GitHub..." -ForegroundColor Cyan

    if (Test-GitInstalled) {
      try {
        Push-Location $repoRoot
        $null = & git pull origin main 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location

        if ($exitCode -eq 0) {
          Write-Ok "[OK] Sync réussie"
        } else {
          Write-Warn "⚠️  Sync impossible - affichage des prompts locaux"
        }
      } catch {
        Write-Warn "⚠️  Sync impossible - affichage des prompts locaux"
      }
    } else {
      Write-Warn "⚠️  Git No installé - affichage des prompts locaux"
    }
  }

  $inv = Get-PromptsInventory $repoRoot

  $domains = @("strategy", "coding", "ops", "trading")
  $domainData = @{}

  foreach ($d in $domains) {
    $domainPrompts = @($inv | Where-Object { $_.Domain -eq $d })

    # ✅ FIX: Forcer tableau vide et vérifier avant .Count
    $uniqueSlugs = @()
    if ($domainPrompts -and $domainPrompts.Count -gt 0) {
      try {
        $temp = @($domainPrompts | Select-Object -ExpandProperty Slug -Unique -ErrorAction SilentlyContinue)
        if ($temp) {
          $uniqueSlugs = @($temp | Sort-Object)
        }
      } catch {
        Write-Warn "Erreur lors du traitement du domaine '$d'"
      }
    }

    $domainData[$d] = @{
      Prompts = $domainPrompts
      UniqueSlugs = $uniqueSlugs
      Count = if ($uniqueSlugs) { $uniqueSlugs.Count } else { 0 }
    }
  }

  Write-Host ""
  Write-Host "Choisis un domaine:" -ForegroundColor Yellow
  Write-Host ""

  $i = 1
  foreach ($d in $domains) {
    $data = $domainData[$d]
    $count = $data.Count

    Write-Host "[$i] " -NoNewline -ForegroundColor Cyan
    Write-Host "$d " -NoNewline -ForegroundColor White

    if ($count -eq 0) {
      Write-Host "(vide)" -ForegroundColor DarkGray
    } else {
      Write-Host "($count prompt(s))" -ForegroundColor Green

      $maxDisplay = 3
      $displayed = 0
      foreach ($slug in $data.UniqueSlugs) {
        if ($displayed -ge $maxDisplay) { break }

        $versions = @($data.Prompts | Where-Object { $_.Slug -eq $slug } | Sort-Object Version -Descending)
        if ($versions -and $versions.Count -gt 0) {
          $latest = $versions[0]
          Write-Host "    • " -NoNewline -ForegroundColor DarkGray
          Write-Host "$slug " -NoNewline -ForegroundColor White
          Write-Host "v$(Format-Version $latest.Version)" -ForegroundColor DarkGray
          $displayed++
        }
      }

      if ($data.UniqueSlugs.Count -gt $maxDisplay) {
        $remaining = $data.UniqueSlugs.Count - $maxDisplay
        Write-Host "    ... et $remaining autre(s)" -ForegroundColor DarkGray
      }
    }

    $i++
  }

  Write-Host ""

  return $domainData
}



# ========================================================================================
# UPDATE SCRIPT - Versionner et uploader promptlab.ps1
# ========================================================================================

function Update-GitPromptScript {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot
  )

  Write-Host ""
  Write-Host "=== UPDATE SCRIPT ===" -ForegroundColor Cyan
  Write-Host ""

  $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $repoRoot "GitPromptOps.ps1" }

  if (-not (Test-Path $scriptPath)) {
    throw "Script introuvable: $scriptPath"
  }

  # Vérifier si le script a des modifications
  Push-Location $repoRoot
  try {
    $status = & git status --porcelain promptlab.ps1 2>&1

    if ([string]::IsNullOrWhiteSpace($status)) {
      Write-Host "Noee modification détectée dans promptlab.ps1" -ForegroundColor Yellow
      Write-Host ""
      $force = Read-Host "Continuer quand même? (y/N)"
      if ($force.ToLowerInvariant() -ne 'y') {
        Pop-Location
        return
      }
    } else {
      Write-Host "Modifications détectées:" -ForegroundColor Green
      Write-Host $status -ForegroundColor DarkGray
      Write-Host ""
    }
  } finally {
    Pop-Location
  }

  # Demander le type de modification
  Write-Host "Type de modification:" -ForegroundColor Yellow
  Write-Host "[1] fix      - Correction de bug" -ForegroundColor Cyan
  Write-Host "[2] feat     - Nouvelle fonctionnalité" -ForegroundColor Cyan
  Write-Host "[3] docs     - Documentation" -ForegroundColor Cyan
  Write-Host "[4] refactor - Refactoring" -ForegroundColor Cyan
  Write-Host "[5] chore    - Maintenance" -ForegroundColor Cyan
  Write-Host ""

  $typeChoice = Read-Host "Choix (1-5)"

  $commitType = switch($typeChoice) {
    "1" { "fix" }
    "2" { "feat" }
    "3" { "docs" }
    "4" { "refactor" }
    "5" { "chore" }
    default { "chore" }
  }

  # Demander le message
  Write-Host ""
  $commitMsg = Read-Host "Description courte (ex: correction Invoke-GitCommitPush CRLF)"

  if ([string]::IsNullOrWhiteSpace($commitMsg)) {
    throw "Message de commit vide"
  }

  $fullCommitMsg = "$commitType(script): $commitMsg"

  # Demander si bump de version
  Write-Host ""
  Write-Host "Bumper la version du script?" -ForegroundColor Yellow
  Write-Host "[1] No - Garder la Current Version" -ForegroundColor Cyan
  Write-Host "[2] Patch - v2.1.0 → v2.1.1" -ForegroundColor Cyan
  Write-Host "[3] Minor - v2.1.0 → v2.2.0" -ForegroundColor Cyan
  Write-Host "[4] Major - v2.1.0 → v3.0.0" -ForegroundColor Cyan
  Write-Host ""

  $versionChoice = Read-Host "Choix (1-4)"

  $bumpVersion = $false
  $versionBump = $null

  if ($versionChoice -ne "1") {
    $bumpVersion = $true
    $versionBump = switch($versionChoice) {
      "2" { "patch" }
      "3" { "minor" }
      "4" { "major" }
      default { "minor" }
    }
  }

  # Si bump de version, modifier le header du script
  if ($bumpVersion) {
    Write-Host ""
    Write-Host "Bump de version ($versionBump)..." -ForegroundColor Yellow

    $scriptContent = Get-Content $scriptPath -Raw

    # Chercher la Current Version dans le header
    if ($scriptContent -match 'v(\d+)\.(\d+)\.(\d+)') {
      $currentMajor = [int]$matches[1]
      $currentMinor = [int]$matches[2]
      $currentPatch = [int]$matches[3]

      $newMajor = $currentMajor
      $newMinor = $currentMinor
      $newPatch = $currentPatch

      switch($versionBump) {
        "patch" { $newPatch++ }
        "minor" { $newMinor++; $newPatch = 0 }
        "major" { $newMajor++; $newMinor = 0; $newPatch = 0 }
      }

      $oldVersion = "v$currentMajor.$currentMinor.$currentPatch"
      $newVersion = "v$newMajor.$newMinor.$newPatch"

      # Remplacer dans le script
      $scriptContent = $scriptContent -replace "v$currentMajor\.$currentMinor\.$currentPatch", $newVersion

      # Backupr
      Set-Content $scriptPath $scriptContent -Encoding UTF8

      Write-Host "Version bumpée: $oldVersion → $newVersion" -ForegroundColor Green

      # Ajouter au message de commit
      $fullCommitMsg = "$fullCommitMsg (bump $newVersion)"
    } else {
      Write-Warn "Version No trouvée dans le header du script"
    }
  }

  Write-Host ""
  Write-Host "Commit: $fullCommitMsg" -ForegroundColor Cyan
  Write-Host ""

  $confirm = Read-Host "Confirmer l'upload? (Y/n)"
  if ($confirm.ToLowerInvariant() -eq 'n') {
    Write-Host "Annulé" -ForegroundColor Yellow
    return
  }

  # Commit + Push
  Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage @($scriptPath) -message $fullCommitMsg

  Write-Host ""
  Write-Ok "Script uploadé avec Success !"
  Write-Host ""
}


# =====================================================
# FIX ULTRA-ROBUSTE - Select-Prompt
# Remplace UNIQUEMENT Select-Prompt dans promptlab.ps1
# =====================================================

function Select-Prompt {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain
  )

  $inv = Get-PromptsInventory $repoRoot
  $domainPrompts = @($inv | Where-Object { $_.Domain -eq $domain })

  if (-not $domainPrompts -or $domainPrompts.Count -eq 0) {
    Write-Warn "Aucun prompt dans le domaine '$domain'."
    return $null
  }

  $slugs = @($domainPrompts | Select-Object -ExpandProperty Slug -Unique | Sort-Object)
  if (-not $slugs -or $slugs.Count -eq 0) {
    Write-Warn "Aucun prompt exploitable dans le domaine '$domain'."
    return $null
  }

  while ($true) {
    Write-Host ""
    Write-Host "Choisis un prompt:" -ForegroundColor Yellow
    Write-Host "[0] Nouveau prompt" -ForegroundColor Cyan

    for ($i = 0; $i -lt $slugs.Count; $i++) {
      $slug = $slugs[$i]
      $latest = Get-LatestPrompt -inv $domainPrompts -domain $domain -slug $slug
      $ver = if ($latest) { "v$(Format-Version $latest.Version)" } else { "v?" }
      Write-Host ("[{0}] {1} {2}" -f ($i + 1), $slug, $ver)
    }

    $choice = Read-Host ("Selection (0-{0})" -f $slugs.Count)
    if ([string]::IsNullOrWhiteSpace($choice)) { return $null }

    if ($choice -match '^\d+$') {
      $n = [int]$choice
      if ($n -eq 0) { return $null }
      if ($n -ge 1 -and $n -le $slugs.Count) { return $slugs[$n - 1] }
      Write-Warn "Choix invalide."
      continue
    }

    try {
      $slugChoice = ConvertTo-Slug $choice
      if ($slugs -contains $slugChoice) { return $slugChoice }
      Write-Warn "Prompt introuvable: $slugChoice"
    } catch {
      Write-Warn $_.Exception.Message
    }
  }
}


# -------------------------
# Helpers: Menu & Interactive Logic
# -------------------------

function Get-CommitMessage-Interactive {
  param(
    [string]$defaultScope,
    [string]$defaultSubject,
    [bool]$askType = $true
  )

  $commitType = "chore"
  if ($askType) {
    Write-Host ""
    Write-Host "Type de modification:" -ForegroundColor Yellow
    Write-Host "[1] feat     - Nouvelle fonctionnalité / Nouveau contenu" -ForegroundColor Cyan
    Write-Host "[2] fix      - Correction / Ajustement" -ForegroundColor Cyan
    Write-Host "[3] docs     - Documentation" -ForegroundColor Cyan
    Write-Host "[4] refactor - Refactoring" -ForegroundColor Cyan
    Write-Host "[5] chore    - Maintenance" -ForegroundColor Cyan

    $c = Read-Host "Choix (1-5) [2]"
    if ([string]::IsNullOrWhiteSpace($c)) { $c = "2" }

    $commitType = switch($c){
      "1" { "feat" }
      "2" { "fix" }
      "3" { "docs" }
      "4" { "refactor" }
      "5" { "chore" }
      default { "fix" }
    }
  }

  Write-Host ""
  $msg = Read-Host "Description courte (ex: $defaultSubject) [ENTER pour défaut]"
  if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultSubject }

  return "$commitType($defaultScope): $msg"
}

function Invoke-Menu([string]$repoRoot){
  while($true){
    Set-Location $script:Config.RepoPath

    $originUrl = $null
    try {
      $originUrl = & git config --get remote.origin.url 2>$null
      if ([string]::IsNullOrWhiteSpace($originUrl)) { $originUrl = $null }
    } catch { $originUrl = $null }

    Write-Box "PROMPT-LAB v7.5 (Enterprise)" @(
      ("Repo: {0}" -f $repoRoot),
      ("Origin: {0}" -f ($originUrl ? $originUrl : "not set")),
      "1) Sync / Update Prompt",
      "2) Bump Version",
      "3) Rollback to version",
      "4) Publish changes",
      "5) Doctor checks",
      "6) Update Script",
      "7) Scan PC repos (delete)",
      "8) Admin / Setup",
      "0) Exit"
    )
    $c = Read-Host "Choix"

    try {
      switch($c){
        "1" {
          Write-Host ""; Write-Host "=== SMART SYNC PROMPT ===" -ForegroundColor Cyan
          Show-DomainPrompt -repoRoot $repoRoot -SyncFirst | Out-Null
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]

          $selectedSlug = Select-Prompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) {
            Write-Host "Création d'un nouveau prompt..." -ForegroundColor Yellow
            $n = Read-Host "Nouveau nom (slug)"
            $v = Read-Host "Version initiale (ex: 0.1.0) [0.1.0]"
            if ([string]::IsNullOrWhiteSpace($v)) { $v = "0.1.0" }
            # Appel direct sans passer par param
            $res = New-PromptOnly -repoRoot $repoRoot -domain $d -name $n -version $v
            $defaultSubject = "initial release v$v"
          } else {
            $n = $selectedSlug
            $f = Read-Host "Fichier source (.md/.txt) (ENTER = paste)"
            $res = Set-PromptContent -repoRoot $repoRoot -domain $d -name $n -fromPath $f -Force:$Force -Yes:$Yes
            $defaultSubject = "update content"
          }

          $mode = Get-GitMode $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject $defaultSubject
            Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "2" {
          Write-Host ""; Write-Host "=== BUMP VERSION ===" -ForegroundColor Cyan
          Show-DomainPrompt -repoRoot $repoRoot | Out-Null
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]
          $selectedSlug = Select-Prompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) { throw "Noe prompt sélectionné" }
          $n = $selectedSlug
          $b = Read-Host "Bump (major/minor/patch) [minor]"
          if ([string]::IsNullOrWhiteSpace($b)){ $b="minor" }
          $res = Update-PromptVersion -repoRoot $repoRoot -domain $d -name $n -bump $b
          $mode = Get-GitMode $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject "bump version ($b)"
            Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "3" {
          Write-Host ""; Write-Host "=== ROLLBACK ===" -ForegroundColor Cyan
          Show-DomainPrompt -repoRoot $repoRoot | Out-Null
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]
          $selectedSlug = Select-Prompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) { throw "Aucun prompt sélectionné" }
          $n = $selectedSlug
          $v = Read-Host "Rollback to version (ex: 1.8.0)"
          $res = Restore-PromptVersion -repoRoot $repoRoot -domain $d -name $n -toVersion $v
          $mode = Get-GitMode $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject "rollback to v$v"
            Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "4" {
          $mode = Get-GitMode $repoRoot
          if($mode -ne "git"){ break }
          $status = Invoke-Git $repoRoot "status --porcelain"
          if([string]::IsNullOrWhiteSpace($status.Out)){ Write-Warn "Rien à publier."; break }
          $msg = Get-CommitMessage-Interactive -defaultScope "global" -defaultSubject "publish updates"
          Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage @("prompts","README.md") -message $msg
        }

        "5" { Test-GitDoctor $repoRoot }
        "6" { Update-GitPromptScript -repoRoot $repoRoot }
        "7" { Invoke-RepoScanner }
        "8" {
          Write-Box "ADMIN / SETUP" @(
            "1) First-run setup wizard",
            "2) Clone repo (URL)",
            "3) Set repo path manually",
            "4) Show current config",
            "0) Back"
          )
          $ac = Read-Host "Choix"
          switch($ac){
            "1" { Initialize-GitPromptSetup }
            "2" {
              $url = Read-Host "Git URL"
              $name = (Split-Path $url -Leaf) -replace "\.git$", ""
              $defaultRoot = Get-GitPromptScriptRoot
              $customRoot = Read-Host "Destination folder (ENTER for $defaultRoot)"
              if ([string]::IsNullOrWhiteSpace($customRoot)) { $customRoot = $defaultRoot }
              $target = Join-Path $customRoot $name
              if (Test-Path $target) {
                Write-Warning "Le dossier existe déjà: $target"
                $reuse = Read-Host "Utiliser ce dossier existant? (Y/N)"
                if ($reuse.ToUpperInvariant() -eq "Y") {
                  $script:Config = @{ RepoPath = $target; RepoName = Split-Path $target -Leaf; Domains = @("strategy","coding","ops","trading"); Version = "7.5.0" }
                  Export-GitPromptConfiguration
                  break
                }
              }
              git clone $url $target
              if ($LASTEXITCODE -eq 0) {
                $script:Config = @{ RepoPath = $target; RepoName = Split-Path $target -Leaf; Domains = @("strategy","coding","ops","trading"); Version = "7.5.0" }
                Export-GitPromptConfiguration
              }
            }
            "3" {
              $newPath = Read-Host "Repo path"
              if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                $script:Config = @{ RepoPath = $newPath; RepoName = Split-Path $newPath -Leaf; Domains = @("strategy","coding","ops","trading"); Version = "7.5.0" }
                Export-GitPromptConfiguration
              }
            }
            "4" {
              Write-Host ("Config file: {0}" -f $script:ConfigFile)
              $script:Config | Format-List | Out-String | Write-Host
              Read-Host "Press ENTER to continue" | Out-Null
            }
            default { }
          }
        }
        "0" { return }
        default { Write-Warn "Choix invalide." }
      }
    } catch {
      Write-Fail $_.Exception.Message
    }
  }
}

# ==========================================
# FINAL DISPATCHER (Main Execution)
# ==========================================
if ($MyInvocation.InvocationName -eq '.') { return }
try {
  $repoRoot = $script:Config.RepoPath
  if (-not $repoRoot) {
      Import-GitPromptConfiguration
      $repoRoot = $script:Config.RepoPath
  }

  # Sécurité : Si toujours pas de repoRoot après load, on force le wizard
  if (-not $repoRoot) {
      Initialize-GitPromptSetup
      $repoRoot = $script:Config.RepoPath
  }

  Initialize-DomainFolder $repoRoot

  switch($Command){
    "menu"    { Invoke-Menu $repoRoot }
    "doctor"  { Test-GitDoctor $repoRoot }
    "index"   {
      $inv = Get-PromptsInventory $repoRoot
      $idx = Build-Index $repoRoot $inv
      Write-Ok ("Index MAJ: " + $idx)
    }
    "pack"    {
      New-PromptLabPack $repoRoot | Out-Null
      Write-Info "Upload: ouvre dist/UPLOAD_INSTRUCTIONS.md"
    }

    "up" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){
        throw "up requiert -Domain et -Name"
      }
      $res = Set-PromptContent -repoRoot $repoRoot -domain $Domain -name $Name `
        -fromPath $From -doReadme:$Readme -Force:$Force -Yes:$Yes
      $mode = Get-GitMode $repoRoot
      if($mode -eq "git"){
        Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: update {0}/{1}" -f $Domain, $res.Slug)
      }
    }

    "sync" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){
        throw "sync requiert -Domain et -Name"
      }
      $res = Set-PromptContent -repoRoot $repoRoot -domain $Domain -name $Name `
        -fromPath $From -doReadme:$Readme -Force:$Force -Yes:$Yes
      $mode = Get-GitMode $repoRoot
      if($mode -eq "git"){
        Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: sync {0}/{1}" -f $Domain, $res.Slug)
      }
    }
    "new" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Version)){
        throw "new requiert -Domain, -Name, -Version"
      }
      $res = New-PromptOnly -repoRoot $repoRoot -domain $Domain -name $Name -version $Version
      $mode = Get-GitMode $repoRoot
      if($mode -eq "git"){
        Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: new {0}/{1} v{2}" -f $Domain, $res.Slug, $Version)
      }
    }

    "bump" {
        if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){ throw "Missing params" }
        $res = Update-PromptVersion -repoRoot $repoRoot -domain $Domain -name $Name -bump $Bump
        $mode = Get-GitMode $repoRoot
        if($mode -eq "git"){
            Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message "bump version"
        }
    }
    "rollback" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($ToVersion)){
        throw "rollback requiert -Domain, -Name, -ToVersion"
      }
      $res = Restore-PromptVersion -repoRoot $repoRoot -domain $Domain -name $Name -toVersion $ToVersion
      $mode = Get-GitMode $repoRoot
      if($mode -eq "git"){
        Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: rollback {0}/{1} to v{2}" -f $Domain, $res.Slug, $ToVersion)
      }
    }
    "publish" {
      $mode = Get-GitMode $repoRoot
      if($mode -ne "git"){ return }
      $status = Invoke-Git $repoRoot "status --porcelain"
      if([string]::IsNullOrWhiteSpace($status.Out)){ Write-Warn "Rien … publier."; return }
      Invoke-GitCommitPush -repoRoot $repoRoot -pathsToStage @("prompts","README.md") `
        -message "promptlab: publish"
    }
  }

  Write-Host ""
  Write-Ok "[OK] Terminé."

} catch {
  Write-Fail $_.Exception.Message
  exit 1
}




