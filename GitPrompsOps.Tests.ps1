#Requires -Modules Pester

$script:backupConfig = $null
$script:scriptPath = $null
$script:configPath = $null

Describe 'GitPromptOps core helpers' {
  BeforeAll {
    $script:backupConfig = $null
    $testRoot = if ($PSScriptRoot) {
      $PSScriptRoot
    } elseif ($PSCommandPath) {
      Split-Path -Parent $PSCommandPath
    } elseif ($MyInvocation.MyCommand.Path) {
      Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
      (Get-Location).Path
    }
    $script:scriptPath = Join-Path $testRoot 'GitPromptOps.ps1'
    $script:configPath = Join-Path $testRoot 'gitprompt-config.json'

    if (Test-Path $script:configPath) {
      $script:backupConfig = Get-Content -Raw -Path $script:configPath -ErrorAction SilentlyContinue
    }

    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'prompts') -Force | Out-Null
    foreach ($d in @('strategy','coding','ops','trading')) {
      New-Item -ItemType Directory -Path (Join-Path $repoRoot ("prompts\$d")) -Force | Out-Null
    }

    $config = @{
      RepoPath = $repoRoot
      RepoName = 'repo'
      Domains  = @('strategy','coding','ops','trading')
      Version  = '7.5.0'
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $script:configPath -Value $config -Encoding UTF8

    . $script:scriptPath

    Set-Variable -Name Version -Value '0.2.0' -Scope Script
    Set-Variable -Name Yes -Value $true -Scope Script
    Set-Variable -Name Force -Value $true -Scope Script
    Set-Variable -Name NormalizeEol -Value $false -Scope Script
    Set-Variable -Name DryRun -Value $false -Scope Script
  }

  AfterAll {
    $backupVar = Get-Variable -Name backupConfig -Scope Script -ErrorAction SilentlyContinue
    $backupValue = if ($backupVar) { $backupVar.Value } else { $null }
    if ($null -ne $backupValue) {
      Set-Content -Path $script:configPath -Value $backupValue -Encoding UTF8
    } else {
      Remove-Item -Path $script:configPath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ConvertTo-Slug normalizes input' {
    ConvertTo-Slug 'My Prompt-Name' | Should -Be 'my_prompt_name'
  }

  It 'ConvertTo-Slug rejects invalid characters' {
    { ConvertTo-Slug 'bad/name' } | Should -Throw
  }

  It 'ConvertTo-Version parses version strings' {
    $v = ConvertTo-Version '1.2.3'
    $v.Major | Should -Be 1
    $v.Minor | Should -Be 2
    $v.Build | Should -Be 3
  }

  It 'Get-NextVersion bumps as expected' {
    $v = ConvertTo-Version '1.2.3'
    (Get-NextVersion $v 'minor').ToString() | Should -Be '1.3.0'
  }

  It 'Get-DomainPrefix returns expected prefix' {
    Get-DomainPrefix 'ops' | Should -Be 'OPS'
  }

  It 'Test-IsMarkdown detects markdown' {
    Test-IsMarkdown "# Title`n- item" | Should -BeTrue
  }

  It 'Resolve-TargetPromptPath rejects explicit paths outside repo' {
    $inv = @()
    { Resolve-TargetPromptPath -repoRoot $script:Config.RepoPath -inv $inv -domain 'ops' -slug 'demo' -explicitPath 'C:\Windows\temp.txt' } | Should -Throw
  }

  It 'Resolve-TargetPromptPath uses Version for new prompt' {
    $inv = @([pscustomobject]@{ Slug = 'other'; Domain = 'ops'; Version = [version]'0.0.0' })
    $res = Resolve-TargetPromptPath -repoRoot $script:Config.RepoPath -inv $inv -domain 'ops' -slug 'demo' -explicitPath $null
    $res.Target | Should -Match '__v0\.1\.0\.md$'
  }

  It 'Build-Index writes index with prompt entries' {
    $prompt = @"
# Sample
"@
    $path = Join-Path $script:Config.RepoPath 'prompts\ops\OPS__sample__v0.1.0.md'
    Set-Content -Path $path -Value $prompt -Encoding UTF8

    $inv = Get-PromptsInventory $script:Config.RepoPath
    $indexPath = Build-Index $script:Config.RepoPath $inv
    Test-Path $indexPath | Should -BeTrue
    (Get-Content -Raw -Path $indexPath) | Should -Match 'sample'
  }
}

Describe 'GitPromptOps git operations (mocked)' {
  BeforeAll {
    if (-not (Get-Command Invoke-Git -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'Get-CurrentGitBranch falls back when branch --show-current is empty' {
    $script:gitCall = 0
    $orig = (Get-Command Invoke-Git).ScriptBlock
    Set-Item -Path function:Invoke-Git -Value {
      $script:gitCall++
      if ($script:gitCall -eq 1) {
        return [pscustomobject]@{ Code = 0; Out = ''; Err = '' }
      }
      return [pscustomobject]@{ Code = 0; Out = 'dev'; Err = '' }
    } -Force
    try {
      $branch = Get-CurrentGitBranch -repoRoot $script:Config.RepoPath
      $branch | Should -Be 'dev'
      $script:gitCall | Should -Be 2
    } finally {
      Set-Item -Path function:Invoke-Git -Value $orig -Force
    }
  }

  It 'Get-GitMode returns git when Git is installed' {
    $orig = (Get-Command Test-GitInstalled).ScriptBlock
    Set-Item -Path function:Test-GitInstalled -Value { $true } -Force
    try {
      (Get-GitMode -repoRoot $script:Config.RepoPath) | Should -Be 'git'
    } finally {
      Set-Item -Path function:Test-GitInstalled -Value $orig -Force
    }
  }

  It 'Get-GitMode returns pack when Git is missing and Yes is set' {
    $script:Yes = $true
    $origTest = (Get-Command Test-GitInstalled).ScriptBlock
    $origPack = (Get-Command New-PromptLabPack).ScriptBlock
    Set-Item -Path function:Test-GitInstalled -Value { $false } -Force
    Set-Item -Path function:New-PromptLabPack -Value { 'dummy.zip' } -Force
    Set-Item -Path function:Read-Host -Value { '1' } -Force
    try {
      (Get-GitMode -repoRoot $script:Config.RepoPath) | Should -Be 'pack'
    } finally {
      Set-Item -Path function:Test-GitInstalled -Value $origTest -Force
      Set-Item -Path function:New-PromptLabPack -Value $origPack -Force
      Remove-Item -Path function:Read-Host -ErrorAction SilentlyContinue
    }
  }
}

Describe 'GitPromptOps filesystem and formatting' {
  BeforeAll {
    if (-not (Get-Command ConvertTo-LfEol -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
    $script:NormalizeEol = $false
    $script:DryRun = $false
  }

  It 'ConvertTo-LfEol normalizes CRLF to LF' {
    ConvertTo-LfEol "a`r`nb`r`n" | Should -Be "a`nb`n"
  }

  It 'Format-Version renders a version object' {
    $v = ConvertTo-Version '2.5.9'
    Format-Version $v | Should -Be '2.5.9'
  }

  It 'New-RepoDirectory creates subfolder inside repo root' {
    $repoRoot = $script:Config.RepoPath
    Push-Location $repoRoot
    try {
      $target = Join-Path $repoRoot 'prompts\\ops\\newdir'
      New-RepoDirectory $target
      Test-Path $target | Should -BeTrue
    } finally {
      Pop-Location
    }
  }

  It 'New-RepoDirectory rejects paths outside repo root' {
    $repoRoot = $script:Config.RepoPath
    Push-Location $repoRoot
    try {
      { New-RepoDirectory 'C:\\Windows\\Temp\\bad' } | Should -Throw
    } finally {
      Pop-Location
    }
  }

  It 'Set-TextFile writes content when not DryRun' {
    $repoRoot = $script:Config.RepoPath
    Push-Location $repoRoot
    try {
      $path = Join-Path $repoRoot 'prompts\\ops\\_test.txt'
      Set-TextFile $path 'ok'
      (Get-Content -Raw -Path $path) | Should -Be 'ok'
    } finally {
      Pop-Location
    }
  }

  It 'Copy-FileBackup creates a backup copy' {
    $repoRoot = $script:Config.RepoPath
    Push-Location $repoRoot
    try {
      $path = Join-Path $repoRoot 'prompts\\ops\\OPS__backup__v0.1.0.md'
      Set-Content -Path $path -Value 'x' -Encoding UTF8
      $backup = Copy-FileBackup $repoRoot $path
      Test-Path $backup | Should -BeTrue
    } finally {
      Pop-Location
    }
  }

  It 'Test-YamlLike detects yaml-like content' {
    Test-YamlLike "metadata: test" | Should -BeTrue
  }

  It 'Convert-ToMarkdownSafe wraps as text when not yaml' {
    $out = Convert-ToMarkdownSafe -text "plain" -title "T"
    $out | Should -Match '```text'
  }

  It 'Convert-ToMarkdownSafe wraps as yaml when yaml-like' {
    $out = Convert-ToMarkdownSafe -text "metadata: test" -title "T"
    $out | Should -Match '```yaml'
  }

  It 'Read-TextFromFile returns content inside repo' {
    $repoRoot = $script:Config.RepoPath
    Push-Location $repoRoot
    try {
      $path = Join-Path $repoRoot 'prompts\\ops\\OPS__read__v0.1.0.md'
      Set-Content -Path $path -Value 'readme' -Encoding UTF8
      (Read-TextFromFile $path).TrimEnd() | Should -Be 'readme'
    } finally {
      Pop-Location
    }
  }
}

Describe 'GitPromptOps README helpers' {
  BeforeAll {
    if (-not (Get-Command Update-Readme -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
    $script:NormalizeEol = $false
  }

  It 'Format-ReadmeUserText converts simple text to markdown' {
    $out = Format-ReadmeUserText -text "Title: Value" -promptTitle "p"
    $out | Should -Match '\*\*Title\*\*: Value'
  }

  It 'Update-Readme writes prompt-scoped README' {
    $repoRoot = $script:Config.RepoPath
    $target = Update-Readme -repoRoot $repoRoot -domain 'ops' -slug 'readme' `
      -promptRelPath 'prompts/ops/OPS__readme__v0.1.0.md' -promptTitle 'ops/readme' `
      -userReadmeText 'notes' -scope 'prompt' -mode 'replace'
    Test-Path $target | Should -BeTrue
    (Get-Content -Raw -Path $target) | Should -Match 'Prompt file'
  }
}

Describe 'GitPromptOps prompt actions' {
  BeforeAll {
    if (-not (Get-Command Set-PromptContent -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
    $script:NormalizeEol = $false
    $script:DryRun = $false
    $script:Yes = $true
    $script:Force = $true
    $script:origPaste = $null
    if (Get-Command Read-TextFromPaste -ErrorAction SilentlyContinue) {
      $script:origPaste = (Get-Command Read-TextFromPaste).ScriptBlock
      Set-Item -Path function:Read-TextFromPaste -Value { 'dummy content' } -Force
    }
  }

  AfterAll {
    if ($script:origPaste) {
      Set-Item -Path function:Read-TextFromPaste -Value $script:origPaste -Force
    }
  }

  It 'Set-PromptContent creates a new prompt file' {
    $repoRoot = $script:Config.RepoPath
    $src = Join-Path $repoRoot 'prompts\\ops\\_src.txt'
    Set-Content -Path $src -Value 'hello' -Encoding UTF8
    $res = Set-PromptContent -repoRoot $repoRoot -domain 'ops' -name 'unit' -fromPath $src -Force:$true -Yes:$true
    Test-Path $res.TargetPrompt | Should -BeTrue
  }

  It 'New-PromptOnly creates an explicit version' {
    $repoRoot = $script:Config.RepoPath
    $name = "newonly_$([guid]::NewGuid().ToString('N').Substring(0,6))"
    $res = New-PromptOnly -repoRoot $repoRoot -domain 'ops' -name $name -version '0.3.0'
    Test-Path $res.TargetPrompt | Should -BeTrue
  }

  It 'Update-PromptVersion bumps version' {
    $repoRoot = $script:Config.RepoPath
    $name = "bumpme_$([guid]::NewGuid().ToString('N').Substring(0,6))"
    New-PromptOnly -repoRoot $repoRoot -domain 'ops' -name $name -version '0.1.0' | Out-Null
    $res = Update-PromptVersion -repoRoot $repoRoot -domain 'ops' -name $name -bump 'minor'
    Test-Path $res.TargetPrompt | Should -BeTrue
  }

  It 'Restore-PromptVersion creates rollback copy' {
    $repoRoot = $script:Config.RepoPath
    $name = "rollback_$([guid]::NewGuid().ToString('N').Substring(0,6))"
    New-PromptOnly -repoRoot $repoRoot -domain 'ops' -name $name -version '0.1.0' | Out-Null
    Update-PromptVersion -repoRoot $repoRoot -domain 'ops' -name $name -bump 'minor' | Out-Null
    $res = Restore-PromptVersion -repoRoot $repoRoot -domain 'ops' -name $name -toVersion '0.1.0'
    Test-Path $res.TargetPrompt | Should -BeTrue
  }
}

Describe 'GitPromptOps misc utilities' {
  BeforeAll {
    if (-not (Get-Command New-UploadInstruction -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'New-UploadInstruction writes instructions file' {
    $repoRoot = $script:Config.RepoPath
    $out = Join-Path $repoRoot 'UPLOAD_INSTRUCTIONS.md'
    New-UploadInstruction -outPath $out -repoUrl 'https://example.com/repo.git'
    Test-Path $out | Should -BeTrue
  }

  It 'Confirm-GitIdentity throws when git config is empty' {
    $orig = Get-Command git -ErrorAction SilentlyContinue
    $hadFunction = $orig -and $orig.CommandType -eq 'Function'
    function git { param([Parameter(ValueFromRemainingArguments=$true)][string[]]$gitArgs) '' }
    try {
      { Confirm-GitIdentity } | Should -Throw
    } finally {
      if ($hadFunction) {
        Set-Item -Path function:git -Value $orig.ScriptBlock -Force
      } else {
        Remove-Item -Path function:git -ErrorAction SilentlyContinue
      }
    }
  }

  It 'Invoke-GitCommitPush rejects empty commit message' {
    $origTest = (Get-Command Test-GitInstalled).ScriptBlock
    $origConfirm = (Get-Command Confirm-GitIdentity).ScriptBlock
    Set-Item -Path function:Test-GitInstalled -Value { $true } -Force
    Set-Item -Path function:Confirm-GitIdentity -Value { } -Force
    try {
      { Invoke-GitCommitPush -repoRoot $script:Config.RepoPath -pathsToStage @() -message '' } | Should -Throw
    } finally {
      Set-Item -Path function:Test-GitInstalled -Value $origTest -Force
      Set-Item -Path function:Confirm-GitIdentity -Value $origConfirm -Force
    }
  }
}

Describe 'GitPromptOps config and setup (mocked)' {
  BeforeAll {
    if (-not (Get-Command Export-GitPromptConfiguration -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'Export/Import-GitPromptConfiguration round-trip config' {
    $repoRoot = $script:Config.RepoPath
    $cfgPath = Join-Path $repoRoot 'config.test.json'
    $script:ConfigFile = $cfgPath
    $script:Config = [pscustomobject]@{ RepoPath = $repoRoot; RepoName = 'repo' }
    Export-GitPromptConfiguration
    $script:Config = $null
    Import-GitPromptConfiguration
    $script:Config.RepoPath | Should -Be $repoRoot
    Remove-Item -Path $cfgPath -Force
  }

  It 'Initialize-GitPromptSetup creates config for local folder (option 3)' {
    $repoRoot = $script:Config.RepoPath
    $cfgPath = Join-Path $repoRoot 'config.setup.json'
    $script:ConfigFile = $cfgPath
    $script:rhResponses = @('3','testrepo')
    function Read-Host {
      param([string]$p)
      if (-not $script:rhResponses -or $script:rhResponses.Count -eq 0) { return '' }
      $value = $script:rhResponses[0]
      if ($script:rhResponses.Count -gt 1) {
        $script:rhResponses = $script:rhResponses[1..($script:rhResponses.Count-1)]
      } else {
        $script:rhResponses = @()
      }
      return $value
    }
    function Clear-Host { }
    Set-Item -Path function:New-Item -Value { param([Parameter(ValueFromRemainingArguments=$true)]$args) } -Force
    try {
      Initialize-GitPromptSetup
      Test-Path $cfgPath | Should -BeTrue
    } finally {
      Remove-Item -Path function:New-Item -ErrorAction SilentlyContinue
      Remove-Item -Path function:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -Path function:Clear-Host -ErrorAction SilentlyContinue
      Remove-Item -Path $cfgPath -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'GitPromptOps network/proxy (mocked)' {
  BeforeAll {
    if (-not (Get-Command Set-GitProxyFromSystem -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'Get-SystemProxyUri returns null or uri without throwing' {
    { Get-SystemProxyUri } | Should -Not -Throw
  }

  It 'Set-GitProxyFromSystem returns false when no proxy' {
    $orig = (Get-Command Get-SystemProxyUri).ScriptBlock
    Set-Item -Path function:Get-SystemProxyUri -Value { $null } -Force
    try {
      Set-GitProxyFromSystem | Should -BeFalse
    } finally {
      Set-Item -Path function:Get-SystemProxyUri -Value $orig -Force
    }
  }

  It 'Test-GitHubConnectivity returns true when Invoke-WebRequest succeeds' {
    $orig = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    function Invoke-WebRequest { param([Parameter(ValueFromRemainingArguments=$true)]$args) @{ StatusCode = 200 } }
    try {
      Test-GitHubConnectivity | Should -BeTrue
    } finally {
      if ($orig -and $orig.CommandType -eq 'Function') {
        Set-Item -Path function:Invoke-WebRequest -Value $orig.ScriptBlock -Force
      } else {
        Remove-Item -Path function:Invoke-WebRequest -ErrorAction SilentlyContinue
      }
    }
  }
}

Describe 'GitPromptOps git setup (mocked)' {
  BeforeAll {
    if (-not (Get-Command Install-GitWizard -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'Install-GitWizard throws on cancel' {
    function Read-Host { param([string]$p) '0' }
    try {
      { Install-GitWizard } | Should -Throw
    } finally {
      Remove-Item -Path function:Read-Host -ErrorAction SilentlyContinue
    }
  }

  It 'Initialize-GitEnvironment calls identity setup when missing' {
    $origTest = (Get-Command Test-GitInstalled).ScriptBlock
    $origSet = (Get-Command Initialize-GitIdentityWizard).ScriptBlock
    $origConfirm = (Get-Command Confirm-GitIdentity).ScriptBlock
    Set-Item -Path function:Test-GitInstalled -Value { $true } -Force
    Set-Item -Path function:Confirm-GitIdentity -Value { throw 'missing' } -Force
    $script:called = $false
    Set-Item -Path function:Initialize-GitIdentityWizard -Value { $script:called = $true } -Force
    try {
      Initialize-GitEnvironment
      $script:called | Should -BeTrue
    } finally {
      Set-Item -Path function:Test-GitInstalled -Value $origTest -Force
      Set-Item -Path function:Initialize-GitIdentityWizard -Value $origSet -Force
      Set-Item -Path function:Confirm-GitIdentity -Value $origConfirm -Force
    }
  }
}

Describe 'GitPromptOps menu flows (mocked)' {
  BeforeAll {
    if (-not (Get-Command Select-Prompt -ErrorAction SilentlyContinue)) {
      . $script:scriptPath
    }
  }

  It 'Select-Prompt returns null on choice 0' {
    $repoRoot = $script:Config.RepoPath
    function Read-Host { param([string]$p) '0' }
    try {
      Select-Prompt -repoRoot $repoRoot -domain 'ops' | Should -Be $null
    } finally {
      Remove-Item -Path function:Read-Host -ErrorAction SilentlyContinue
    }
  }

  It 'Select-Prompt returns slug for numeric selection' {
    $repoRoot = $script:Config.RepoPath
    $path = Join-Path $repoRoot 'prompts\\ops\\OPS__sel__v0.1.0.md'
    Set-Content -Path $path -Value 'x' -Encoding UTF8
    function Read-Host { param([string]$p) 'sel' }
    try {
      Select-Prompt -repoRoot $repoRoot -domain 'ops' | Should -Be 'sel'
    } finally {
      Remove-Item -Path function:Read-Host -ErrorAction SilentlyContinue
    }
  }

  It 'Show-DomainPrompt returns domain data' {
    $repoRoot = $script:Config.RepoPath
    $result = Show-DomainPrompt -repoRoot $repoRoot
    $result.Keys.Count | Should -BeGreaterThan 0
  }
}
