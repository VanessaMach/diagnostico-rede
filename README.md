# Diagnóstico de Rede para Windows

Projeto de infraestrutura de TI desenvolvido para auxiliar no diagnóstico inicial de conectividade em computadores Windows.

O projeto utiliza um script em **PowerShell** para consultar configurações de rede, realizar testes de conectividade e gerar um relatório em texto.

## Objetivo

Ajudar a investigar possíveis problemas de conexão por meio de testes que podem ser comparados e analisados.

O script registra os resultados, mas não determina automaticamente a causa de uma falha. Por exemplo, um equipamento pode não responder ao ping mesmo estando ligado, caso esse tipo de resposta esteja bloqueado.

## O que o script faz

1. Consulta as interfaces de rede disponíveis.
2. Identifica endereços IPv4 e servidores DNS informados pelo Windows.
3. Identifica os gateways IPv4 configurados.
4. Testa a resposta dos gateways ao ping.
5. Testa a resposta do endereço externo `1.1.1.1`.
6. Consulta o endereço `www.microsoft.com` por DNS.
7. Exibe os resultados no terminal.
8. Gera um relatório de texto com data e hora.

O script consulta a configuração e executa testes de conectividade. Ele não altera adaptadores, rotas, DNS, firewall ou serviços.

## Tecnologias utilizadas

- **Windows**
- **PowerShell**
- **Git e GitHub**
- **Visual Studio Code**
- **GitHub Spec Kit**, utilizado no planejamento do projeto
- **GitHub Copilot**, utilizado como apoio ao desenvolvimento

## Requisitos

- Windows 10 ou Windows 11.
- Windows PowerShell 5.1.

Os testes externos dependem da conexão disponível e das regras da rede.

## Como executar

1. Abra o PowerShell na pasta do projeto.
2. Execute:

```powershell
powershell.exe -NoProfile -File .\diagnostico-rede.ps1
```

Ao final da execução, o caminho do relatório será exibido no terminal.

O arquivo será salvo na pasta `relatorios`, criada ao lado do script. Seu nome contém a data e o horário da execução.

> As mensagens exibidas pelo script estão em inglês.

## Como executar os testes automatizados

Na pasta raiz do projeto, execute:

```powershell
powershell.exe -NoProfile -File .\tests\diagnostico-rede.tests.ps1
```

Se os testes forem concluídos com sucesso, a mensagem esperada é:

```text
All diagnostic tests passed.
```

Os testes automatizados utilizam respostas simuladas para verificar comportamentos de sucesso e falha, sem depender da conexão real.

## Testes realizados

O diagnóstico foi executado em três situações:

| Cenário | Resultado observado |
|---|---|
| **Conexão ativa** | Os gateways e o endereço externo responderam ao ping, e a consulta DNS foi concluída. |
| **Wi-Fi desconectado** | Os gateways e o endereço externo não responderam ao ping, e a consulta DNS excedeu o tempo limite. |
| **Wi-Fi reconectado** | Os testes voltaram a receber respostas. |

Os arquivos na pasta [exemplos](exemplos/) apresentam **resumos anonimizados de testes reais**. Nomes e endereços do ambiente foram omitidos.

Os relatórios originais são gerados localmente na pasta `relatorios` e estão configurados para serem ignorados pelo Git.

## Como interpretar os resultados

| Estado | Significado |
|---|---|
| `SUCCESS` | A consulta ou o teste recebeu o resultado esperado. |
| `FAILED` | O teste falhou ou encontrou um erro. |
| `NOT RUN` | O teste não foi executado, por exemplo, por falta de um gateway identificado. |

O sucesso na consulta da configuração local significa que o Windows forneceu informações sobre uma interface. **Isso não confirma, sozinho, que a interface possui acesso à internet.**

O programa pode encerrar com código `0` mesmo que algum teste individual apresente `FAILED`: nesse caso, o diagnóstico foi concluído e o relatório foi salvo. Os resultados de cada teste devem ser consultados no relatório.

## Principais comandos

| Comando | Função no projeto |
|---|---|
| `Get-NetIPConfiguration` | Consulta interfaces, endereços e servidores DNS configurados no Windows. |
| `Test-NetConnection` | Testa se um destino responde à verificação de conectividade. |
| `Resolve-DnsName` | Consulta o DNS para obter o endereço IPv4 de um nome. |
| `Get-Date` | Registra a data e o horário da execução. |
| `Out-File` | Salva os resultados em um arquivo de texto. |

## Limitações

- Os testes de conectividade foram planejados para **IPv4**. Problemas específicos de IPv6 não são avaliados.
- A ausência de resposta ao ping pode ocorrer por bloqueios ou falhas de comunicação; ela não identifica a causa sozinha.
- A consulta DNS e os testes externos dependem das condições e configurações da rede.
- As mensagens do script e dos relatórios estão em inglês.

## Privacidade

A pasta `relatorios` está indicada no `.gitignore` para evitar que novos relatórios sejam adicionados normalmente ao Git.

## Aprendizados

Com este projeto, pratiquei:

- Consulta de configurações de rede no Windows.
- Interpretação de endereços IPv4, gateways e servidores DNS.
- Testes de conectividade e comparação de resultados.
- Automação de tarefas com PowerShell.
- Registro de evidências e documentação técnica.
- Uso de Git, GitHub e ferramentas de apoio ao desenvolvimento.

## Autora

**Vanessa Machado Rodrigues**

Estudante de Engenharia de Computação com interesse em suporte e infraestrutura de TI.