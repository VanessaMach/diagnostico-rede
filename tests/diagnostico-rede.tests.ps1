$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }

    Assert-True $threw $Message
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'diagnostico-rede.ps1'
$projectReportDirectory = Join-Path $projectRoot 'relatorios'
$reportDirectoryExistedBefore = Test-Path $projectReportDirectory
$testReportDirectory = Join-Path $env:TEMP ('diagnostico-rede-tests-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $testReportDirectory -Force | Out-Null
    . $scriptPath

    Assert-True ($null -ne (Get-Command Invoke-NetworkDiagnostic -ErrorAction SilentlyContinue)) 'Dot-sourcing must define the diagnostic entry function.'
    Assert-True ($null -ne (Get-Command New-DiagnosticResult -ErrorAction SilentlyContinue)) 'Dot-sourcing must define the result helper.'
    Assert-Equal (Test-Path $projectReportDirectory) $reportDirectoryExistedBefore 'Dot-sourcing must not create report output or run diagnostics.'

    $startedAt = [datetime]::Parse('2026-11-16T10:20:30.123')
    $successResult = New-DiagnosticResult -Name 'DNS lookup' -Target 'www.microsoft.com' -Status 'SUCCESS' -Details 'An A record was returned.' -ObservedAt $startedAt
    $failureResult = New-DiagnosticResult -Name 'External reachability' -Target '1.1.1.1' -Status 'FAILED' -Details 'No ping reply was received.' -ObservedAt $startedAt
    $skippedResult = New-DiagnosticResult -Name 'Gateway reachability' -Target '' -Status 'NOT RUN' -Details 'No default gateway was found.' -ObservedAt $startedAt

    Assert-Equal $successResult.Status 'SUCCESS' 'Successful checks must retain their status.'
    Assert-Equal $failureResult.Status 'FAILED' 'Failed checks must retain their status.'
    Assert-Equal $skippedResult.Status 'NOT RUN' 'Skipped checks must retain their status.'
    Assert-Throws { New-DiagnosticResult -Name 'Invalid' -Target '' -Status 'UNKNOWN' -Details 'Invalid status.' } 'Unknown result states must be rejected.'

    $reportPath = Write-DiagnosticReport -Results @($successResult, $failureResult, $skippedResult) -StartedAt $startedAt -ReportDirectory $testReportDirectory
    Assert-True (Test-Path $reportPath -PathType Leaf) 'The report writer must create a text report.'
    Assert-True ((Split-Path -Parent $reportPath) -eq $testReportDirectory) 'The test report must use the supplied temporary directory.'
    Assert-True ((Split-Path -Leaf $reportPath) -match '^network-diagnostic-20261116-102030123\.txt$') 'The report name must include the run timestamp through milliseconds.'

    $reportContent = [System.IO.File]::ReadAllText($reportPath, [System.Text.Encoding]::UTF8)
    foreach ($expectedText in @('DNS lookup', 'www.microsoft.com', 'SUCCESS', 'FAILED', 'NOT RUN', 'No ping reply was received.')) {
        Assert-True ($reportContent.Contains($expectedText)) "The report must include '$expectedText'."
    }

    $blockedDirectory = Join-Path $testReportDirectory 'not-a-directory'
    Set-Content -Path $blockedDirectory -Value 'This file blocks directory creation.' -Encoding UTF8
    Assert-Throws { Write-DiagnosticReport -Results @($successResult) -StartedAt $startedAt -ReportDirectory $blockedDirectory } 'Report write failures must be surfaced to the caller.'
    $reportFailureMessage = ''
    try {
        Write-DiagnosticReport -Results @($successResult) -StartedAt $startedAt -ReportDirectory $blockedDirectory
    }
    catch {
        $reportFailureMessage = $_.Exception.Message
    }
    Assert-True ($reportFailureMessage -match "^Unable to write the diagnostic report to '.+'\.$") 'Report write errors must use a stable English message without localized exception text.'

    $global:testReportDirectory = $testReportDirectory
    $global:probeTargets = @()
    $global:includeTestGateway = $true
    $global:targetFailures = @()
    $global:targetErrors = @()
    $global:dnsShouldFail = $false
    $global:configurationShouldFail = $false
    $global:localizedErrorMessage = 'Error localizado de prueba.'

    function Get-ReportDirectory {
        param([string]$BasePath = $PSScriptRoot)
        $global:testReportDirectory
    }

    function Get-NetworkConfiguration {
        if ($global:configurationShouldFail) {
            throw $global:localizedErrorMessage
        }

        $testGateways = @()
        if ($global:includeTestGateway) {
            $testGateways = @([pscustomobject]@{ NextHop = '192.0.2.1' })
        }

        @([pscustomobject]@{
            InterfaceAlias = 'Ethernet'
            IPv4Address = @([pscustomobject]@{ IPAddress = '192.0.2.10' })
            DNSServer = [pscustomobject]@{ ServerAddresses = @('192.0.2.53') }
            IPv4DefaultGateway = $testGateways
        })
    }

    function Test-NetworkTarget {
        param([string]$Target)
        $global:probeTargets += $Target

        if ($global:targetErrors -contains $Target) {
            throw $global:localizedErrorMessage
        }

        [pscustomobject]@{ PingSucceeded = ($global:targetFailures -notcontains $Target) }
    }

    function Resolve-DiagnosticName {
        param([string]$Name)
        $global:dnsQueryName = $Name

        if ($global:dnsShouldFail) {
            throw $global:localizedErrorMessage
        }

        @([pscustomobject]@{ Type = 'A'; IPAddress = '203.0.113.10' })
    }

    $run = Invoke-NetworkDiagnostic
    Assert-Equal $run.Results.Count 4 'A successful run must contain the local, gateway, external, and DNS checks.'
    Assert-True ($global:probeTargets -contains '192.0.2.1') 'The configured gateway must be tested.'
    Assert-True ($global:probeTargets -contains '1.1.1.1') 'The documented external IPv4 reference must be tested.'
    Assert-Equal $global:dnsQueryName 'www.microsoft.com' 'The documented DNS reference must be queried.'
    Assert-True (Test-Path $run.ReportPath -PathType Leaf) 'A successful run must save a report.'

    $runReport = [System.IO.File]::ReadAllText($run.ReportPath, [System.Text.Encoding]::UTF8)
    foreach ($expectedText in @('Local network configuration', '192.0.2.1', '1.1.1.1', 'www.microsoft.com', 'SUCCESS')) {
        Assert-True ($runReport.Contains($expectedText)) "The successful run report must include '$expectedText'."
    }

    $global:includeTestGateway = $false
    $global:probeTargets = @()
    $noGatewayRun = Invoke-NetworkDiagnostic
    $noGatewayResult = @($noGatewayRun.Results | Where-Object { $_.Name -eq 'Gateway reachability' })[0]
    Assert-Equal $noGatewayResult.Status 'NOT RUN' 'A missing gateway must be reported as not run.'
    Assert-True ($global:probeTargets -contains '1.1.1.1') 'External reachability must continue when no gateway exists.'
    Assert-True (-not ($global:probeTargets -contains '192.0.2.1')) 'A missing gateway must not be probed.'
    Assert-True (Test-Path $noGatewayRun.ReportPath -PathType Leaf) 'A missing gateway must not prevent report creation.'

    $global:configurationShouldFail = $true
    $global:probeTargets = @()
    $global:targetErrors = @()
    $global:targetFailures = @()
    $global:dnsShouldFail = $false
    $configurationFailureRun = Invoke-NetworkDiagnostic
    $configurationFailure = @($configurationFailureRun.Results | Where-Object { $_.Name -eq 'Local network configuration' })[0]
    $skippedGateway = @($configurationFailureRun.Results | Where-Object { $_.Name -eq 'Gateway reachability' })[0]
    Assert-Equal $configurationFailure.Status 'FAILED' 'A local configuration error must be recorded.'
    Assert-Equal $skippedGateway.Status 'NOT RUN' 'Gateway reachability must be skipped when configuration is unavailable.'
    Assert-True ($configurationFailureRun.Results.Name -contains 'External IPv4 reachability') 'The external check must continue after a configuration error.'
    Assert-True ($configurationFailureRun.Results.Name -contains 'DNS lookup') 'DNS must continue after a configuration error.'
    Assert-True ($global:probeTargets -contains '1.1.1.1') 'The external probe must run after a configuration error.'
    Assert-Equal $global:dnsQueryName 'www.microsoft.com' 'DNS must run after a configuration error.'
    Assert-True (Test-Path $configurationFailureRun.ReportPath -PathType Leaf) 'A configuration error must not prevent report creation.'
    Assert-True (-not $configurationFailure.Details.Contains($global:localizedErrorMessage)) 'Configuration errors must not expose localized exception text.'
    $global:configurationShouldFail = $false

    $global:includeTestGateway = $true
    $global:probeTargets = @()
    $global:targetErrors = @('192.0.2.1', '1.1.1.1')
    $global:targetFailures = @('1.1.1.1')
    $global:dnsShouldFail = $true
    $partialFailureRun = Invoke-NetworkDiagnostic
    $gatewayFailure = @($partialFailureRun.Results | Where-Object { $_.Name -eq 'Gateway reachability' })[0]
    $externalFailure = @($partialFailureRun.Results | Where-Object { $_.Name -eq 'External IPv4 reachability' })[0]
    $dnsFailure = @($partialFailureRun.Results | Where-Object { $_.Name -eq 'DNS lookup' })[0]
    Assert-Equal $gatewayFailure.Status 'FAILED' 'A gateway probe exception must be recorded as failed.'
    Assert-Equal $externalFailure.Status 'FAILED' 'No external ping reply must be recorded as failed.'
    Assert-Equal $dnsFailure.Status 'FAILED' 'A DNS exception must be recorded as failed.'
    Assert-True (-not $gatewayFailure.Details.Contains($global:localizedErrorMessage)) 'Gateway errors must not expose localized exception text.'
    Assert-True (-not $externalFailure.Details.Contains($global:localizedErrorMessage)) 'External probe errors must not expose localized exception text.'
    Assert-True (-not $dnsFailure.Details.Contains($global:localizedErrorMessage)) 'DNS errors must not expose localized exception text.'
    Assert-True ($dnsFailure.Details.Contains('does not identify a cause')) 'DNS failure details must not claim a root cause.'
    Assert-True (Test-Path $partialFailureRun.ReportPath -PathType Leaf) 'Probe failures must not prevent report creation.'
    Assert-True ($global:probeTargets -contains '1.1.1.1') 'The external probe must run after a gateway exception.'
    Assert-Equal $global:dnsQueryName 'www.microsoft.com' 'DNS must run after a gateway exception.'

    $global:testReportDirectory = $blockedDirectory
    Assert-Throws { Invoke-NetworkDiagnostic } 'A report-write failure must be surfaced after the checks complete.'
    $previousErrorWriter = [Console]::Error
    $errorWriter = New-Object System.IO.StringWriter
    try {
        [Console]::SetError($errorWriter)
        $entrypointExitCode = Start-DiagnosticApplication
    }
    finally {
        [Console]::SetError($previousErrorWriter)
    }
    Assert-Equal $entrypointExitCode 1 'A fatal report-write failure must return a non-zero process status.'
    Assert-True ($errorWriter.ToString().Contains('Unable to complete the diagnostic.')) 'A fatal report-write failure must emit a stable English error.'
    $errorWriter.Dispose()
    $global:testReportDirectory = $testReportDirectory

    $formattedSuccess = Format-DiagnosticResult -Result $successResult
    Assert-True ($formattedSuccess -match '^\[SUCCESS\] DNS lookup - Target: www\.microsoft\.com; ') 'User-facing status output must use the documented English format.'

    $scriptContent = Get-Content -Raw $scriptPath
    Assert-True ($scriptContent.Contains('# Consulta a configuracao local')) 'The script must explain its functions with Portuguese comments.'
    Assert-True ($scriptContent.Contains('Report saved to:')) 'The successful report message must be in English.'
    Assert-True ($scriptContent.Contains('Unable to complete the diagnostic.')) 'The fatal error message must be in English.'

    $readmePath = Join-Path $projectRoot 'README.md'
    Assert-True (Test-Path $readmePath -PathType Leaf) 'Beginner instructions must be available in README.md.'
    $readmeContent = Get-Content -Raw $readmePath
    foreach ($expectedText in @('Windows PowerShell 5.1', '.\diagnostico-rede.ps1', '.\tests\diagnostico-rede.tests.ps1', 'relatorios', 'SUCCESS', 'FAILED', 'NOT RUN', 'um teste isolado nao confirma a causa')) {
        Assert-True ($readmeContent.Contains($expectedText)) "README.md must include '$expectedText'."
    }

    Write-Output 'All diagnostic tests passed.'
}
finally {
    if (Test-Path $testReportDirectory) {
        Remove-Item -Path $testReportDirectory -Recurse -Force
    }
}
