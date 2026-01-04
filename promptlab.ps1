<# 
promptlab.ps1 — Prompt-Lab automation (REFACTORED - Security Enhanced v3.4.0 FIXED)

SECURITY IMPROVEMENTS:
✓ Command injection prevention (Git operations)
✓ Path traversal validation
✓ ReDoS protection (regex timeouts)
✓ Dynamic branch detection
✓ SupportsShouldProcess (-WhatIf/-Confirm)
✓ Enhanced parameter validation
✓ Improved error handling

Usage (fast path):
  .\promptlab.ps1                 # menu
  .\promptlab.ps1 up   -Domain trading -Name deadweight -From .\new.txt
  .\promptlab.ps1 sync -Domain trading -Name deadweight -From .\new.txt
  .\promptlab.ps1 bump -Domain trading -Name deadweight -Bump minor
  .\promptlab.ps1 doctor
  .\promptlab.ps1 index
  .\promptlab.ps1 rollback -Domain trading -Name deadweight -ToVersion 1.8.0
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
  [Parameter(Position=0)]
  [ValidateSet("menu","doctor","up","sync","new","bump","index","publish","pack","rollback")]
  [string]$Command = "menu",

  [ValidateSet("strategy","coding","ops","trading")]
  [string]$Domain,

  [ValidateScript({ 
    if ($_ -match '[\\\/\.\:\*\?\"\<\>\|]') { 
      throw "Name contains invalid characters. Use letters, numbers, spaces, hyphens, underscores only." 
    }
    $true 
  })]
  [string]$Name,

  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  [ValidateSet("major","minor","patch")]
  [string]$Bump = "minor",

  [ValidateScript({ 
    if (-not [string]::IsNullOrWhiteSpace($_) -and -not (Test-Path $_ -PathType Leaf)) { 
      throw "File not found: $_" 
    }
    $true 
  })]
  [string]$From,

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
  [string]$RepoUrl = "",

  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$ToVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# SECURITY: Set default regex timeout to prevent ReDoS attacks
if ($PSVersionTable.PSVersion.Major -ge 7) {
  [System.Text.RegularExpressions.Regex]::s_defaultMatchTimeout = [TimeSpan]::FromSeconds(2)
}

# -------------------------
# Helpers: output
# -------------------------
function Write-Info([string]$m){ Write-Host ("[INFO]  " + $m) }
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
  } catch {}
}

function Configure-GitProxyFromSystem {
  $proxyUri = Get-SystemProxyUri
  if ([string]::IsNullOrWhiteSpace($proxyUri)) { return $false }
  try {
    & git config --global http.proxy "$proxyUri" 2>$null | Out-Null
    & git config --global https.proxy "$proxyUri" 2>$null | Out-Null
    Write-Ok "Proxy détecté et appliqué à Git: $proxyUri"
    return $true
  } catch {
    Write-Warn "Proxy détecté mais configuration Git proxy impossible."
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
    "Le script peut tenter winget, sinon guider l'installation manuelle/portable."
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
  Write-Host "[0] Annuler" -ForegroundColor Cyan

  $c = Read-Host "Choix (0-3)"
  if ($c -eq "0") { throw "Git requis. Installation annulée." }

  if ($c -eq "1") {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
      Write-Warn "winget introuvable (ou désactivé)."
      Write-Info "Astuce: 'winget --info' peut indiquer des politiques d'entreprise."
      $c = "2"
    } else {
      try {
        Enable-SystemProxyForSession
        Write-Info "Commande: winget install --id Git.Git -e --source winget"
        $args = "install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements"
        $p = Start-Process -FilePath "winget" -ArgumentList $args -Wait -PassThru
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
    throw "Git non installé"
  }

  if ($c -eq "3") {
    Write-Box "INSTALLATION PORTABLE" @(
      "Utilise l'édition Portable (thumbdrive) depuis:",
      "https://git-scm.com/downloads/win",
      "Puis ajoute le dossier 'cmd' de PortableGit au PATH et relance."
    )
    throw "Git non installé"
  }
}

function Setup-GitIdentityWizard {
  Write-Box "CONFIGURATION GIT" @("Configuration de user.name / user.email / core.autocrlf")

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

function Ensure-GitReady {
  if (-not (Test-GitInstalled)) { Install-GitWizard }
  Configure-GitProxyFromSystem | Out-Null
  try { Git-EnsureIdentity } catch { Setup-GitIdentityWizard }
}

function Run-AutoSetup {
  param([string]$targetDir)

  Write-Box "AUTO-SETUP (New PC)" @(
    "Repo Prompt-Lab non détecté dans le dossier courant.",
    "Le script peut cloner automatiquement le repo GitHub."
  )

  Ensure-GitReady

  if (-not (Test-GitHubConnectivity)) {
    Write-Warn "Accès à https://github.com semble bloqué (firewall/proxy/SSL inspection)."
    Write-Info "Si SSL est intercepté: demande à l'IT d'ajouter le certificat racine corporate dans Windows (Trusted Root)."
    Write-Info "Évite de désactiver http.sslVerify (non recommandé)."
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

function Ensure-Dir([string]$p){
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

function Normalize-EolToLF([string]$text){
  return ($text -replace "`r`n", "`n") -replace "`r", "`n"
}

function Save-TextFile([string]$path, [string]$content){
  if (-not $path) { throw "Path cannot be null" }

  $dir = Split-Path $path -Parent
  Ensure-Dir $dir

  if ($NormalizeEol){ $content = Normalize-EolToLF $content }

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

function Backup-File([string]$repoRoot, [string]$filePath){
  if (-not (Test-Path $filePath)) { return $null }

  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $backupRoot = Join-Path $repoRoot (".backup\" + $ts)
  $relative = $filePath

  if ($filePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)){
    $relative = $filePath.Substring($repoRoot.Length).TrimStart("\","/")
  }

  $dest = Join-Path $backupRoot $relative
  $destDir = Split-Path $dest -Parent
  Ensure-Dir $destDir

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
function To-Slug([string]$s){
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

function Domain-Prefix([string]$domain){
  switch($domain){
    "strategy" { "STR" }
    "coding"   { "COD" }
    "ops"      { "OPS" }
    "trading"  { "TRD" }
    default    { throw "Domaine invalide: $domain" }
  }
}

function Parse-Version([string]$v){
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

function Next-Version([version]$v, [string]$bump){
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

function Looks-LikeYaml([string]$text){
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
  if (Looks-LikeYaml $t){
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
function Ensure-DomainFolders([string]$repoRoot){
  $root = Join-Path $repoRoot "prompts"
  Ensure-Dir $root
  foreach($d in @("strategy","coding","ops","trading")){
    Ensure-Dir (Join-Path $root $d)
  }
}

function Get-PromptsInventory([string]$repoRoot){
  $promptsRoot = Join-Path $repoRoot "prompts"
  Ensure-Dir $promptsRoot
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
        Write-Warn "Skipping non-standard prompt file: $($f.Name)"
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
        Version = (Parse-Version $verStr)
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
  $matches = $inv | Where-Object { $_.Slug -eq $slug -and $_.Domain -eq $domain }
  if (-not $matches) { return $null }
  return ($matches | Sort-Object Version -Descending | Select-Object -First 1)
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
  $lines.Add(("Total prompts: {0}" -f $latest.Count))
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
  $lines.Add("## 🛠️ Code Projects & Scripts")
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

  Save-TextFile $indexPath ($lines -join "`n")
  return $indexPath
}

function Select-PromptInteractive([object[]]$matches){
  $i = 1
  foreach($m in ($matches | Sort-Object Version -Descending)){
    Write-Host ("[{0}] {1}  v{2}  ({3} KB)" -f $i, $m.RelPath, (Format-Version $m.Version), $m.SizeKB)
    $i++
  }

  $pick = Read-Host "Sélection (1-$($matches.Count))"
  $n = 0
  if (-not [int]::TryParse($pick, [ref]$n)) { throw "Sélection invalide." }
  if ($n -lt 1 -or $n -gt $matches.Count) { throw "Sélection hors limites." }
  return (($matches | Sort-Object Version -Descending)[$n-1])
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
  $matches = @()
  if ($inv -and $inv.Count -gt 0) {
    $temp = @($inv | Where-Object { $_.Slug -eq $slug -and $_.Domain -eq $domain } | Sort-Object Version -Descending)
    if ($temp) { 
      $matches = $temp 
    }
  }

  if (-not $matches -or $matches.Count -eq 0){
    $v = if([string]::IsNullOrWhiteSpace($Version)) { [version]"0.1.0" } else { Parse-Version $Version }
    $prefix = Domain-Prefix $domain
    $file = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $v))
    $target = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $file)
    return [pscustomobject]@{ Mode="new"; Target=$target; Existing=$null }
  }

  if ($matches.Count -eq 1){
    return [pscustomobject]@{ Mode="existing"; Target=$matches[0].Path; Existing=$matches[0] }
  }

  if ($Yes){
    return [pscustomobject]@{ Mode="existing"; Target=$matches[0].Path; Existing=$matches[0] }
  }

  Write-Box "Plusieurs versions trouvées" @("Sélectionne le prompt à remplacer:")
  $pick = Select-PromptInteractive $matches
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
  $out.Add("# $promptTitle — README")
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
  if ($NormalizeEol){ $formatted = Normalize-EolToLF $formatted }

  if ($scope -eq "prompt"){
    $folder = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $slug)
    Ensure-Dir $folder
    $target = Join-Path $folder "README.md"
    if (Test-Path $target){ Backup-File $repoRoot $target | Out-Null }
    $ref = "`n`n---`n`n**Prompt file**: ``$($promptRelPath)```n"
    if ($formatted -notmatch '(?m)^\*\*Prompt file\*\*:'){
      $formatted = $formatted + $ref
    }
    Save-TextFile $target $formatted
    return $target
  }

  $target = if ($scope -eq "domain") {
    $folder = Join-Path $repoRoot ("prompts\{0}" -f $domain)
    Ensure-Dir $folder
    Join-Path $folder "README.md"
  } else {
    Join-Path $repoRoot "README.md"
  }

  if (Test-Path $target){ Backup-File $repoRoot $target | Out-Null }

  if ($mode -eq "replace"){
    Save-TextFile $target $formatted
    return $target
  }

  $safeSlug = $slug -replace '[^a-zA-Z0-9_]', ''
  $markerKey = $safeSlug.ToUpperInvariant()
  $start = "<!-- PROMPTLAB:$markerKey:START -->"
  $end   = "<!-- PROMPTLAB:$markerKey:END -->"
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
    Save-TextFile $target $block
    return $target
  }

  if ($existing -like "*$start*"){
    try {
      $pattern = [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
      $regex = [regex]::new($pattern, "Singleline", [TimeSpan]::FromSeconds(1))
      $new = $regex.Replace($existing, $block)
      Save-TextFile $target $new
    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
      throw 'Timeout processing README markers - file may be too large or corrupted'
    }
    return $target
  }

  Save-TextFile $target ($existing.TrimEnd() + "`n`n" + $block + "`n")
  return $target
}

# -------------------------
# Git operations - SECURITY ENHANCED
# -------------------------
function Git-Run([string]$repoRoot, [string]$args){
  if (-not (Test-GitInstalled)) { throw "Git not installed" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "git"
  $psi.Arguments = $args
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
      throw "Git command timeout after 30 seconds: $args"
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

function Git-GetCurrentBranch([string]$repoRoot) {
  $result = Git-Run $repoRoot "branch --show-current"
  if ($result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Out)) {
    $result = Git-Run $repoRoot "rev-parse --abbrev-ref HEAD"
    if ($result.Code -ne 0) {
      throw "Unable to determine current branch"
    }
  }
  return $result.Out.Trim()
}

function Git-EnsureIdentity {
  $name = (git config --global user.name 2>$null)
  $email = (git config --global user.email 2>$null)
  if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)){
    throw 'Identité Git manquante. Fix: git config --global user.name "Nom" ; git config --global user.email "you@example.com"'
  }
}



# =====================================================
# Git-Doctor ENHANCED - Version 2.1
# Avec gestion automatique LF/CRLF et auto-fix complet
# =====================================================

function Read-YesNo([string]$prompt) {
  $answer = Read-Host "$prompt"
  return ($answer.ToLowerInvariant() -eq 'y')
}

function Git-Doctor([string]$repoRoot){
  $issues = @()
  $fixed = @()

  Write-Box "PROMPT-LAB Doctor" @("Diagnostic en cours...")

  # ========================================
  # CHECK 1: Git installé
  # ========================================
  if (-not (Test-GitInstalled)){
    $issues += "Git non installé"
    Write-Warn "❌ Git n'est pas installé"
    Write-Host "   📥 Télécharge: https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host "   ⚠️  Mode 'pack ZIP' disponible comme alternative" -ForegroundColor Yellow
    return
  }
  Write-Ok "✓ Git installé"

  # ========================================
  # CHECK 1.5: Configuration Git autocrlf (NOUVEAU)
  # ========================================
  try {
    Push-Location $repoRoot
    $autocrlf = & git config core.autocrlf 2>$null
    Pop-Location

    if ($autocrlf -ne "true") {
      Write-Warn "⚠️  Git autocrlf non configuré (peut causer des problèmes LF/CRLF)"

      if ($Yes -or (Read-YesNo "   🔧 Configurer autocrlf=true? (Y/N)")) {
        try {
          & git config --global core.autocrlf true
          Write-Ok "   ✓ Git autocrlf configuré"
          $fixed += "Git autocrlf"
        } catch {
          Write-Warn "   ⚠️  Impossible de configurer autocrlf"
        }
      }
    } else {
      Write-Ok "✓ Git autocrlf configuré"
    }
  } catch {
    Write-Warn "⚠️  Impossible de vérifier autocrlf"
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
    $issues += "Repo non initialisé"
    Write-Warn "❌ Pas de repo Git détecté dans: $repoRoot"

    if ($Yes -or (Read-YesNo "   🔧 Initialiser Git maintenant? (Y/N)")) {
      try {
        Push-Location $repoRoot
        $initOutput = & git init 2>&1
        $initExitCode = $LASTEXITCODE
        Pop-Location

        if ($initExitCode -eq 0) {
          Write-Ok "   ✓ Git initialisé"
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
            Write-Info "   ✓ .gitignore créé"
          }

          # Configurer branche par défaut
          try {
            Push-Location $repoRoot
            & git config init.defaultBranch main 2>&1 | Out-Null
            Pop-Location
          } catch {}

          # Refresh status
          $gitInitialized = $true

        } else {
          Write-Fail "   ✗ Échec init: $initOutput"
        }
      } catch {
        Write-Fail "   ✗ Erreur: $($_.Exception.Message)"
      }
    } else {
      Write-Info "   💡 Manuel: cd '$repoRoot' puis exécute 'git init'"
    }
  } else {
    Write-Ok "✓ Repo Git valide"
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
        Ensure-DomainFolders $repoRoot
        Write-Ok "   ✓ Dossiers créés: prompts/{strategy,coding,ops,trading}"
        $fixed += "Structure prompts/"
      } catch {
        Write-Fail "   ✗ Échec création: $($_.Exception.Message)"
      }
    } else {
      Write-Info "   💡 Manuel: mkdir prompts\strategy,prompts\coding,prompts\ops,prompts\trading"
    }
  } else {
    Write-Ok "✓ Structure prompts/ présente"

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
        Write-Ok "   ✓ Sous-dossiers créés: $($missing -join ', ')"
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
      $issues += "Identité Git non configurée"
      Write-Warn "❌ Identité Git manquante"

      if ($Yes -or (Read-YesNo "   🔧 Configurer maintenant? (Y/N)")) {
        $userName = Read-Host "   👤 Nom complet (ex: Jean Dupont)"
        $userEmail = Read-Host "   📧 Email (ex: jean@example.com)"

        if (-not [string]::IsNullOrWhiteSpace($userName) -and -not [string]::IsNullOrWhiteSpace($userEmail)) {
          & git config --global user.name "$userName"
          & git config --global user.email "$userEmail"
          Write-Ok "   ✓ Identité configurée: $userName <$userEmail>"
          $fixed += "Git identity"
        } else {
          Write-Warn "   ⚠️  Identité non configurée (champs vides)"
        }
      } else {
        Write-Host "   💡 Manuel: git config --global user.name 'Ton Nom'" -ForegroundColor Cyan
        Write-Host "              git config --global user.email 'ton@email.com'" -ForegroundColor Cyan
      }
    } else {
      Write-Ok "✓ Identité Git: $name <$email>"
    }
  } catch {
    Write-Warn "⚠️  Impossible de vérifier l'identité Git"
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
        Write-Ok "✓ Branche active: $branch"
      } else {
        Write-Warn "⚠️  Aucune branche active (normal si repo vide - fais un premier commit)"
      }
    } catch {
      Write-Warn "⚠️  Impossible de détecter la branche"
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
        Write-Ok "✓ Remote configuré:"
        $remote -split "`n" | Select-Object -First 2 | ForEach-Object { 
          Write-Host "     $_" -ForegroundColor DarkGray 
        }
      } else {
        Write-Warn "⚠️  Aucun remote GitHub/GitLab configuré (local seulement)"
        Write-Host "   💡 Pour ajouter: git remote add origin <URL>" -ForegroundColor Cyan
      }
    } catch {
      Write-Warn "⚠️  Impossible de vérifier remote"
    }
  }


# ========================================
# CHECK 7: État du repo
# ========================================
if ($gitInitialized) {
  try {
    Push-Location $repoRoot
    $status = & git status --porcelain 2>$null
    $statusExitCode = $LASTEXITCODE
    Pop-Location

    if ($statusExitCode -eq 0){
      if ([string]::IsNullOrWhiteSpace($status)){
        Write-Ok "✓ Repo clean (aucun changement non commité)"
      } else {
        $fileCount = ($status -split "`n" | Where-Object {$_}).Count
        Write-Warn "⚠️  Repo dirty: $fileCount fichier(s) modifié(s)"

        if ($Yes -or (Read-YesNo "   🔧 Créer un commit initial? (Y/N)")) {
          try {
            Push-Location $repoRoot
            
            # Ajouter les fichiers
            & git add . 2>&1 | Out-Null
            
            # Créer le commit en ignorant les warnings CRLF
            $commitMsg = "chore: initial prompt-lab setup"
            $commitOutput = & git -c core.safecrlf=false commit -m "$commitMsg" 2>&1
            $commitExitCode = $LASTEXITCODE
            
            Pop-Location

            if ($commitExitCode -eq 0) {
              Write-Ok "   ✓ Commit initial créé"
              $fixed += "Initial commit"
            } else {
              Write-Fail "   ✗ Échec commit"
              Write-Info "   💡 Essaie manuellement: git add . && git -c core.safecrlf=false commit -m 'init'"
            }
          } catch {
            try { Pop-Location } catch {}
            Write-Fail "   ✗ Erreur: $($_.Exception.Message)"
          }
        }
      }
    }
  } catch {
    Write-Warn "⚠️  Impossible de vérifier l'état du repo"
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
        Write-Ok "   ✓ README.md créé"
        $fixed += "README.md"
      } catch {
        Write-Fail "   ✗ Échec création README: $($_.Exception.Message)"
      }
    }
  } else {
    Write-Ok "✓ README.md présent"
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
        Write-Ok "   ✓ Index généré"
        $fixed += "Index"
      } catch {
        Write-Fail "   ✗ Échec génération index: $($_.Exception.Message)"
      }
    }
  } else {
    Write-Ok "✓ Index prompts présent"
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
    Write-Host "Toutes les issues ont été corrigées !" -ForegroundColor Green
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
    Write-Host "Issues non résolues: " -NoNewline -ForegroundColor Red
    Write-Host ($issues -join ', ')
    Write-Host ""
    Write-Host "💡 Relance 'doctor' pour corriger interactivement" -ForegroundColor Cyan
  }

  Write-Host ""
}



function Git-CommitPush {
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string[]]$pathsToStage,
    [Parameter(Mandatory)][string]$message
  )

  if (-not (Test-GitInstalled)){ throw "Git non installé." }
  Git-EnsureIdentity

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
        Write-Host "[INFO] Nothing to commit" -ForegroundColor Yellow
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
function New-UploadInstructions([string]$outPath, [string]$repoUrl){
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
- ✓ prompts/_index.md is updated
- ✓ Version numbers are correct
- ✓ README links work

---
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@
  Save-TextFile $outPath $txt.TrimEnd()
}

function New-PromptLabPack([string]$repoRoot){
  $dist = Join-Path $repoRoot "dist"
  Ensure-Dir $dist
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $instructions = Join-Path $dist "UPLOAD_INSTRUCTIONS.md"
  New-UploadInstructions $instructions $RepoUrl
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

function Ensure-GitOrOfferPack([string]$repoRoot){
  if (Test-GitInstalled){ return "git" }

  Write-Box "Git non détecté" @(
    "Option 1 (recommandé): Générer un ZIP 'upload-ready' + instructions GitHub web.",
    "Option 2: Annuler."
  )
  $choice = if($Yes){"1"} else { Read-Host "Choisis (1/2)" }
  if ($choice -ne "1"){ throw "Annulé." }

  $zip = New-PromptLabPack $repoRoot
  Write-Info "Upload: ouvre dist/UPLOAD_INSTRUCTIONS.md"
  return "pack"
}

# -------------------------
# Core actions
# -------------------------
function Prompt-UpdateOrCreate {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter()][string]$fromPath,
    [Parameter()][switch]$doReadme
  )

  Ensure-DomainFolders $repoRoot
  $slug = To-Slug $name
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

  Backup-File $repoRoot $target | Out-Null
  Save-TextFile $target $content
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

function Prompt-NewOnly {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$version
  )

  Ensure-DomainFolders $repoRoot
  $slug = To-Slug $name
  $inv = Get-PromptsInventory $repoRoot

  if (Get-LatestPrompt $inv $domain $slug){ 
    throw "Prompt existe déjà. Utilise 'up' ou 'sync'." 
  }

  $prefix = Domain-Prefix $domain
  $v = Parse-Version $version
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

  Save-TextFile $target $content
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

function Prompt-BumpVersion {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$bump
  )

  $slug = To-Slug $name
  $inv = Get-PromptsInventory $repoRoot
  $latest = Get-LatestPrompt $inv $domain $slug
  if (-not $latest){ throw "Prompt introuvable pour bump: $domain/$slug" }

  $newV = Next-Version $latest.Version $bump
  $prefix = Domain-Prefix $domain
  $newFile = ("{0}__{1}__v{2}.md" -f $prefix, $slug, (Format-Version $newV))
  $dest = Join-Path $repoRoot ("prompts\{0}\{1}" -f $domain, $newFile)

  if (Test-Path $dest -and -not $Force){ 
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

function Prompt-Rollback {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$repoRoot,
    [Parameter(Mandatory)][string]$domain,
    [Parameter(Mandatory)][string]$name,
    [Parameter(Mandatory)][string]$toVersion
  )

  $slug = To-Slug $name
  $inv = Get-PromptsInventory $repoRoot
  $targetVer = Parse-Version $toVersion

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

  $latest = Get-LatestPrompt $inv $domain $slug
  if ($latest.Version -eq $targetVer) {
    Write-Warn "Already at version $toVersion"
    return
  }

  if (-not $PSCmdlet.ShouldProcess("$domain/$slug", "Rollback to v$toVersion")) {
    throw "Annulé par l'utilisateur."
  }

  $newV = Next-Version $latest.Version "minor"
  $prefix = Domain-Prefix $domain
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
# Remplace Menu-PickDomain et Menu-Run dans promptlab.ps1
# =====================================================



# =====================================================
# FIX COMPLET - TOUTES LES FONCTIONS
# Remplace Show-DomainWithPrompts ET Menu-PickPrompt
# =====================================================

# -------------------------
# Fonction 1: Show-DomainWithPrompts (CORRIGÉE)
# -------------------------

function Show-DomainWithPrompts {
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
        $pullResult = & git pull origin main 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location

        if ($exitCode -eq 0) {
          Write-Ok "✓ Sync réussie"
        } else {
          Write-Warn "⚠️  Sync impossible - affichage des prompts locaux"
        }
      } catch {
        Write-Warn "⚠️  Sync impossible - affichage des prompts locaux"
      }
    } else {
      Write-Warn "⚠️  Git non installé - affichage des prompts locaux"
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

function Update-Script {
  param(
    [Parameter(Mandatory)][string]$repoRoot
  )
  
  Write-Host ""
  Write-Host "=== UPDATE SCRIPT ===" -ForegroundColor Cyan
  Write-Host ""
  
  $scriptPath = Join-Path $repoRoot "promptlab.ps1"
  
  if (-not (Test-Path $scriptPath)) {
    throw "Script introuvable: $scriptPath"
  }
  
  # Vérifier si le script a des modifications
  Push-Location $repoRoot
  try {
    $status = & git status --porcelain promptlab.ps1 2>&1
    
    if ([string]::IsNullOrWhiteSpace($status)) {
      Write-Host "Aucune modification détectée dans promptlab.ps1" -ForegroundColor Yellow
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
  $commitMsg = Read-Host "Description courte (ex: correction Git-CommitPush CRLF)"
  
  if ([string]::IsNullOrWhiteSpace($commitMsg)) {
    throw "Message de commit vide"
  }
  
  $fullCommitMsg = "$commitType(script): $commitMsg"
  
  # Demander si bump de version
  Write-Host ""
  Write-Host "Bumper la version du script?" -ForegroundColor Yellow
  Write-Host "[1] Non - Garder la version actuelle" -ForegroundColor Cyan
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
    
    # Chercher la version actuelle dans le header
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
      
      # Sauvegarder
      Set-Content $scriptPath $scriptContent -Encoding UTF8
      
      Write-Host "Version bumpée: $oldVersion → $newVersion" -ForegroundColor Green
      
      # Ajouter au message de commit
      $fullCommitMsg = "$fullCommitMsg (bump $newVersion)"
    } else {
      Write-Warn "Version non trouvée dans le header du script"
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
  Git-CommitPush -repoRoot $repoRoot -pathsToStage @($scriptPath) -message $fullCommitMsg
  
  Write-Host ""
  Write-Ok "Script uploadé avec succès !"
  Write-Host ""
}




# =====================================================
# FIX ULTRA-ROBUSTE - Menu-PickPrompt
# Remplace UNIQUEMENT Menu-PickPrompt dans promptlab.ps1
# =====================================================






# -------------------------
# Menu Principal AMÉLIORÉ
# -------------------------

# -------------------------
# Menu (TUI) - v3.3
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

function Menu-Run([string]$repoRoot){
  while($true){
    Write-Box "PROMPT-LAB v3.3 (Corporate Edition)" @(
      "1) Sync / Update Prompt (Create or Update)",
      "2) Bump Version (Copy latest -> new)",
      "3) Rollback to version",
      "4) Publish changes (commit + push)",
      "5) Doctor (checks + fixes)",
      "6) Update Script (self-update promptlab.ps1)",
      "0) Exit"
    )
    $c = Read-Host "Choix"

    try {
      switch($c){
        "1" {
          Write-Host ""; Write-Host "=== SMART SYNC PROMPT ===" -ForegroundColor Cyan
          $domainInfo = Show-DomainWithPrompts -repoRoot $repoRoot -SyncFirst
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]

          $selectedSlug = Menu-PickPrompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) {
            Write-Host "Création d'un nouveau prompt..." -ForegroundColor Yellow
            $n = Read-Host "Nouveau nom (slug)"
            $v = Read-Host "Version initiale (ex: 0.1.0) [0.1.0]"
            if ([string]::IsNullOrWhiteSpace($v)) { $v = "0.1.0" }
            $res = Prompt-NewOnly -repoRoot $repoRoot -domain $d -name $n -version $v
            $defaultSubject = "initial release v$v"
          } else {
            $n = $selectedSlug
            $f = Read-Host "Fichier source (.md/.txt) (ENTER = paste)"
            $res = Prompt-UpdateOrCreate -repoRoot $repoRoot -domain $d -name $n -fromPath $f
            $defaultSubject = "update content"
          }

          $mode = Ensure-GitOrOfferPack $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject $defaultSubject
            Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "2" {
          Write-Host ""; Write-Host "=== BUMP VERSION ===" -ForegroundColor Cyan
          $domainInfo = Show-DomainWithPrompts -repoRoot $repoRoot
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]
          $selectedSlug = Menu-PickPrompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) { throw "Aucun prompt sélectionné" }
          $n = $selectedSlug
          $b = Read-Host "Bump (major/minor/patch) [minor]"
          if ([string]::IsNullOrWhiteSpace($b)){ $b="minor" }
          $res = Prompt-BumpVersion -repoRoot $repoRoot -domain $d -name $n -bump $b
          $mode = Ensure-GitOrOfferPack $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject "bump version ($b)"
            Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "3" {
          Write-Host ""; Write-Host "=== ROLLBACK ===" -ForegroundColor Cyan
          $domainInfo = Show-DomainWithPrompts -repoRoot $repoRoot
          $domainChoice = Read-Host "Sélection domaine (1-4)"
          $domainMap = @{ "1"="strategy"; "2"="coding"; "3"="ops"; "4"="trading" }
          if (-not $domainMap.ContainsKey($domainChoice)) { throw "Choix invalide" }
          $d = $domainMap[$domainChoice]
          $selectedSlug = Menu-PickPrompt -repoRoot $repoRoot -domain $d
          if ($null -eq $selectedSlug) { throw "Aucun prompt sélectionné" }
          $n = $selectedSlug
          $v = Read-Host "Rollback to version (ex: 1.8.0)"
          $res = Prompt-Rollback -repoRoot $repoRoot -domain $d -name $n -toVersion $v
          $mode = Ensure-GitOrOfferPack $repoRoot
          if($mode -eq "git"){
            $msg = Get-CommitMessage-Interactive -defaultScope "$d/$n" -defaultSubject "rollback to v$v"
            Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths -message $msg
          }
        }

        "4" {
          $mode = Ensure-GitOrOfferPack $repoRoot
          if($mode -ne "git"){ break }
          $status = Git-Run $repoRoot "status --porcelain"
          if([string]::IsNullOrWhiteSpace($status.Out)){ Write-Warn "Rien à publier."; break }
          $msg = Get-CommitMessage-Interactive -defaultScope "global" -defaultSubject "publish updates"
          Git-CommitPush -repoRoot $repoRoot -pathsToStage @("prompts","README.md","promptlab.ps1") -message $msg
        }

        "5" { Git-Doctor $repoRoot }
        "6" { Update-Script -repoRoot $repoRoot }
        "0" { return }
        default { Write-Warn "Choix invalide." }
      }
    } catch {
      Write-Fail $_.Exception.Message
      if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
      }
    }
  }
}

# -------------------------
# Dispatch
# -------------------------
try {
  $repoRoot = Get-RepoRoot
  if ($null -eq $repoRoot) { Run-AutoSetup -targetDir (Get-Location).Path }
  Ensure-DomainFolders $repoRoot

  switch($Command){
    "menu"    { Menu-Run $repoRoot }
    "doctor"  { Git-Doctor $repoRoot }
    "index"   { 
      $inv = Get-PromptsInventory $repoRoot
      $idx = Build-Index $repoRoot $inv
      Write-Ok ("Index MAJ: " + $idx) 
    }
    "pack"    { 
      $zip = New-PromptLabPack $repoRoot
      Write-Info "Upload: ouvre dist/UPLOAD_INSTRUCTIONS.md" 
    }

    "up" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){ 
        throw "up requiert -Domain et -Name" 
      }
      $res = Prompt-UpdateOrCreate -repoRoot $repoRoot -domain $Domain -name $Name `
        -fromPath $From -doReadme:$Readme
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -eq "git"){ 
        Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: update {0}/{1}" -f $Domain, $res.Slug) 
      }
    }

    "sync" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){ 
        throw "sync requiert -Domain et -Name" 
      }
      $res = Prompt-UpdateOrCreate -repoRoot $repoRoot -domain $Domain -name $Name `
        -fromPath $From -doReadme:$Readme
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -eq "git"){ 
        Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: sync {0}/{1}" -f $Domain, $res.Slug) 
      }
    }

    "new" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Version)){
        throw "new requiert -Domain, -Name, -Version"
      }
      $res = Prompt-NewOnly -repoRoot $repoRoot -domain $Domain -name $Name -version $Version
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -eq "git"){ 
        Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: new {0}/{1} v{2}" -f $Domain, $res.Slug, $Version) 
      }
    }

    "bump" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name)){ 
        throw "bump requiert -Domain et -Name" 
      }
      $res = Prompt-BumpVersion -repoRoot $repoRoot -domain $Domain -name $Name -bump $Bump
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -eq "git"){ 
        Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: bump {0}/{1} {2}" -f $Domain, $res.Slug, $Bump) 
      }
    }

    "rollback" {
      if ([string]::IsNullOrWhiteSpace($Domain) -or [string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($ToVersion)){
        throw "rollback requiert -Domain, -Name, -ToVersion"
      }
      $res = Prompt-Rollback -repoRoot $repoRoot -domain $Domain -name $Name -toVersion $ToVersion
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -eq "git"){ 
        Git-CommitPush -repoRoot $repoRoot -pathsToStage $res.ChangedPaths `
          -message ("promptlab: rollback {0}/{1} to v{2}" -f $Domain, $res.Slug, $ToVersion) 
      }
    }

    "publish" {
      $mode = Ensure-GitOrOfferPack $repoRoot
      if($mode -ne "git"){ return }
      $status = Git-Run $repoRoot "status --porcelain"
      if([string]::IsNullOrWhiteSpace($status.Out)){ Write-Warn "Rien à publier."; return }
      Git-CommitPush -repoRoot $repoRoot -pathsToStage @("prompts","README.md") `
        -message "promptlab: publish"
    }
  }

  Write-Host ""
  Write-Ok "✓ Operation completed successfully"

} catch {
  Write-Fail $_.Exception.Message
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "Stack trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
  }
  exit 1
}

