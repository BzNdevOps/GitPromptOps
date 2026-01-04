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
