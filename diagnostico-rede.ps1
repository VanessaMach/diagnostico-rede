# Cria um resultado padronizado para a tela e para o relatorio.
function New-DiagnosticResult {
    param(
        [string]$Name,
        [string]$Target,
        [ValidateSet('SUCCESS', 'FAILED', 'NOT RUN')]
        [string]$Status,
        [string]$Details,
        [datetime]$ObservedAt = (Get-Date)
    )

    [pscustomobject]@{
        Name       = $Name
        Target     = $Target
        Status     = $Status
        Details    = $Details
        ObservedAt = $ObservedAt
    }
}

# Mantem os relatorios junto ao script, sem depender da pasta atual do terminal.
function Get-ReportDirectory {
    param([string]$BasePath = $PSScriptRoot)

    Join-Path -Path $BasePath -ChildPath 'relatorios'
}

# Reune os resultados em texto UTF-8 e salva o relatorio com data e hora.
# Se a gravacao falhar, o erro chega ao ponto de entrada para indicar codigo 1.
function Write-DiagnosticReport {
    param(
        [object[]]$Results,
        [datetime]$StartedAt,
        [string]$ReportDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
        $ReportDirectory = Get-ReportDirectory
    }

    $fileTimestamp = $StartedAt.ToString('yyyyMMdd-HHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
    $reportPath = Join-Path -Path $ReportDirectory -ChildPath "network-diagnostic-$fileTimestamp.txt"

    try {
        New-Item -ItemType Directory -Path $ReportDirectory -Force -ErrorAction Stop | Out-Null

        $lines = @(
            'Network Diagnostic Report'
            "Started: $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture))"
            ''
        )

        foreach ($result in $Results) {
            $lines += "[$($result.Status)] $($result.Name)"
            if (-not [string]::IsNullOrWhiteSpace($result.Target)) {
                $lines += "Target: $($result.Target)"
            }

            $lines += "Details: $($result.Details)"
            $lines += "Observed at: $($result.ObservedAt.ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture))"
            $lines += ''
        }

        $lines | Out-File -LiteralPath $reportPath -Encoding UTF8 -Force -ErrorAction Stop
        return $reportPath
    }
    catch {
        throw "Unable to write the diagnostic report to '$reportPath'."
    }
}

# Consulta cada interface sem alterar sua configuracao de rede.
# Os campos IPv4Address e DNSServer fornecem os enderecos IPv4 e servidores DNS
# que a rotina principal apresenta junto ao nome da interface.
function Get-NetworkConfiguration {
    Get-NetIPConfiguration -ErrorAction Stop
}

# Reune gateways IPv4 distintos para evitar repetir verificacoes.
# Cada NextHop e um endereco de gateway; ordenar e remover duplicatas evita
# testar o mesmo gateway mais de uma vez.
function Get-GatewayCandidates {
    param([object[]]$Configurations)

    $gatewayAddresses = foreach ($configuration in $Configurations) {
        foreach ($gateway in @($configuration.IPv4DefaultGateway)) {
            if ($null -ne $gateway -and -not [string]::IsNullOrWhiteSpace($gateway.NextHop)) {
                [string]$gateway.NextHop
            }
        }
    }

    @($gatewayAddresses | Sort-Object -Unique)
}

# Verifica se o destino responde a um pedido ICMP sem alterar a rede.
function Test-NetworkTarget {
    param([string]$Target)

    Test-NetConnection -ComputerName $Target -InformationLevel Detailed -WarningAction SilentlyContinue -ErrorAction Stop
}

# Consulta um registro DNS A sem usar o arquivo hosts local.
function Resolve-DiagnosticName {
    param([string]$Name)

    Resolve-DnsName -Name $Name -Type A -DnsOnly -NoHostsFile -ErrorAction Stop
}

# Formata uma linha curta em ingles para cada resultado exibido.
function Format-DiagnosticResult {
    param([object]$Result)

    $targetDescription = ''
    if (-not [string]::IsNullOrWhiteSpace($Result.Target)) {
        $targetDescription = "Target: $($Result.Target); "
    }

    "[$($Result.Status)] $($Result.Name) - $targetDescription$($Result.Details)"
}

# Executa as consultas em sequencia e registra falhas sem parar as outras.
function Invoke-NetworkDiagnostic {
    $startedAt = Get-Date
    $results = @()
    $configurations = @()
    $configurationAvailable = $false

    try {
        $configurations = @(Get-NetworkConfiguration)
        if ($configurations.Count -eq 0) {
            throw 'No network configuration was returned.'
        }

        foreach ($configuration in $configurations) {
            $addresses = @($configuration.IPv4Address | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
            $dnsServers = @($configuration.DNSServer | ForEach-Object { $_.ServerAddresses } | ForEach-Object { $_ } | Where-Object { $_ })
            $addressSummary = if ($addresses.Count -gt 0) { $addresses -join ', ' } else { 'None reported' }
            $dnsSummary = if ($dnsServers.Count -gt 0) { $dnsServers -join ', ' } else { 'None reported' }
            $details = "Interface: $($configuration.InterfaceAlias); IPv4 addresses: $addressSummary; DNS servers: $dnsSummary"

            $results += New-DiagnosticResult -Name 'Local network configuration' -Target $configuration.InterfaceAlias -Status 'SUCCESS' -Details $details
        }

        $configurationAvailable = $true
    }
    catch {
        $results += New-DiagnosticResult -Name 'Local network configuration' -Target '' -Status 'FAILED' -Details 'Configuration query failed.'
    }

    $gatewayCandidates = @()
    $gatewayDiscoveryFailed = $false
    if ($configurationAvailable) {
        try {
            $gatewayCandidates = @(Get-GatewayCandidates -Configurations $configurations)
        }
        catch {
            $gatewayDiscoveryFailed = $true
            $results += New-DiagnosticResult -Name 'Gateway discovery' -Target '' -Status 'FAILED' -Details 'Gateway query failed.'
        }
    }

    # Sem configuracao ou sem gateway, o teste fica como NOT RUN; caso contrario,
    # cada gateway encontrado e testado separadamente.
    if (-not $gatewayDiscoveryFailed) {
        if (-not $configurationAvailable) {
            $results += New-DiagnosticResult -Name 'Gateway reachability' -Target '' -Status 'NOT RUN' -Details 'The gateway check was skipped because local configuration was unavailable.'
        }
        elseif ($gatewayCandidates.Count -eq 0) {
            $results += New-DiagnosticResult -Name 'Gateway reachability' -Target '' -Status 'NOT RUN' -Details 'No default IPv4 gateway was found; the gateway reachability check was not run.'
        }
        else {
            foreach ($gatewayAddress in $gatewayCandidates) {
                try {
                    $probe = Test-NetworkTarget -Target $gatewayAddress
                    if ($probe.PingSucceeded) {
                        $status = 'SUCCESS'
                        $details = 'A ping reply was received.'
                    }
                    else {
                        $status = 'FAILED'
                        $details = 'No ping reply was received; this result alone does not identify a cause.'
                    }

                    $results += New-DiagnosticResult -Name 'Gateway reachability' -Target $gatewayAddress -Status $status -Details $details
                }
                catch {
                    $results += New-DiagnosticResult -Name 'Gateway reachability' -Target $gatewayAddress -Status 'FAILED' -Details 'Gateway probe failed.'
                }
            }
        }
    }

    # Testa 1.1.1.1 por ICMP para verificar se o endereco IPv4 externo responde.
    # A falta de resposta descreve somente este teste e nao confirma uma causa.
    try {
        $externalProbe = Test-NetworkTarget -Target '1.1.1.1'
        if ($externalProbe.PingSucceeded) {
            $externalStatus = 'SUCCESS'
            $externalDetails = 'A ping reply was received.'
        }
        else {
            $externalStatus = 'FAILED'
            $externalDetails = 'No ping reply was received; this result alone does not identify a cause.'
        }

        $results += New-DiagnosticResult -Name 'External IPv4 reachability' -Target '1.1.1.1' -Status $externalStatus -Details $externalDetails
    }
    catch {
        $results += New-DiagnosticResult -Name 'External IPv4 reachability' -Target '1.1.1.1' -Status 'FAILED' -Details 'External probe failed.'
    }

    # Consulta por DNS o registro A de www.microsoft.com; nao usa o arquivo hosts.
    try {
        $dnsAnswers = @(Resolve-DiagnosticName -Name 'www.microsoft.com')
        $resolvedAddresses = @($dnsAnswers | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
        if ($resolvedAddresses.Count -eq 0) {
            $results += New-DiagnosticResult -Name 'DNS lookup' -Target 'www.microsoft.com' -Status 'FAILED' -Details 'The DNS query returned no A records.'
        }
        else {
            $results += New-DiagnosticResult -Name 'DNS lookup' -Target 'www.microsoft.com' -Status 'SUCCESS' -Details "Resolved IPv4 address(es): $($resolvedAddresses -join ', ')"
        }
    }
    catch {
        $results += New-DiagnosticResult -Name 'DNS lookup' -Target 'www.microsoft.com' -Status 'FAILED' -Details 'DNS query failed; this result alone does not identify a cause.'
    }

    # Grava todas as verificacoes em um arquivo cujo nome inclui data e horario.
    $reportPath = Write-DiagnosticReport -Results $results -StartedAt $startedAt -ReportDirectory (Get-ReportDirectory)
    [pscustomobject]@{
        StartedAt = $startedAt
        Results = $results
        ReportPath = $reportPath
    }
}

# Devolve 0 quando o relatorio foi salvo; em falha fatal, informa o erro e devolve 1.
function Start-DiagnosticApplication {
    try {
        $run = Invoke-NetworkDiagnostic
        foreach ($result in $run.Results) {
            [Console]::Out.WriteLine((Format-DiagnosticResult -Result $result))
        }

        [Console]::Out.WriteLine("Report saved to: $($run.ReportPath)")
        return 0
    }
    catch {
        [Console]::Error.WriteLine('Unable to complete the diagnostic.')
        return 1
    }
}

# Executado diretamente, o codigo retornado encerra o processo com 0 ou 1.
# Ao carregar o arquivo em testes, define as funcoes sem iniciar o diagnostico.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Start-DiagnosticApplication)
}
