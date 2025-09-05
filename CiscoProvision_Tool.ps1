<# 
Cisco Provisioning Tool (ISR 4321 Routers & Catalyst 2960 Switch)
- Standalone functions ONLY (kein Admin-Toolkit).
- Fragt: Router oder Switch? Bei Router: welcher (1/2/3)?
- Setzt auch Passwörter (enable secret + lokaler Admin-User) und spielt OSPF-/Mgmt-Config.
- Erwartet, dass SSH auf den Geräten erreichbar ist (sonst initiale Konsolen-Konfig notwendig).

Nutzung:
  Install-Module Posh-SSH -Scope CurrentUser -Force
  .\CiscoProvision_Tool.ps1
  Invoke-CiscoProvisionInteractive

Optional: Nicht-interaktiv
  $cred = Get-Credential
  $cfg = Get-CiscoDeviceConfig -Type router -RouterNumber 1 -Username admin -UserSecret 'CISCOlab!123' -EnableSecret 'CISCOenable!123'
  Invoke-CiscoConfig -Host $cfg.Host -Credential $cred -ConfigLines $cfg.Lines
#>

#Requires -Modules Posh-SSH

param(
    [Parameter(Mandatory = $false)][int]$SshPort = 22
)

function Ensure-PoshSSH {
    try {
        if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
            Write-Host "Installiere Posh-SSH Modul..." -ForegroundColor Yellow
            Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false
        }
        Import-Module Posh-SSH -ErrorAction Stop
    } catch {
        throw "Posh-SSH konnte nicht geladen werden: $($_.Exception.Message)"
    }
}

function Convert-SecureToPlain {
    param([Parameter(Mandatory=$true)][SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
}

function New-SSHShell {
    param(
        [Parameter(Mandatory=$true)][string]$Host,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
        [int]$Port = 22
    )
    $session = New-SSHSession -ComputerName $Host -Port $Port -Credential $Credential -AcceptKey -ErrorAction Stop
    try {
        $stream = New-SSHShellStream -SessionId $session.SessionId -TerminalName 'xterm' -TerminalWidth 200 -TerminalHeight 80 -BufferSize 8192
        return [PSCustomObject]@{ Session = $session; Stream = $stream }
    } catch {
        if ($session) { Remove-SSHSession -SessionId $session.SessionId | Out-Null }
        throw
    }
}

function Wait-UntilPrompt {
    param(
        [Parameter(Mandatory=$true)]$Stream,
        [int]$TimeoutSec = 8
    )
    $output = ""
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($Stream.DataAvailable) {
            $chunk = $Stream.Read()
            if ($null -ne $chunk) { $output += $chunk }
            if ($output -match "(?m)[>#]\s*$|\(config[^\)]*\)#\s*$") { break }
        } else { Start-Sleep -Milliseconds 100 }
    }
    return $output
}

function Send-CiscoCommand {
    param(
        [Parameter(Mandatory=$true)]$Stream,
        [Parameter(Mandatory=$true)][string]$Command,
        [int]$TimeoutSec = 8
    )
    $Stream.WriteLine($Command)
    Start-Sleep -Milliseconds 100
    return Wait-UntilPrompt -Stream $Stream -TimeoutSec $TimeoutSec
}

function Invoke-CiscoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Host,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
        [string[]]$ConfigLines,
        [int]$Port = 22,
        [string]$EnablePassword,  # falls benötigt
        [string]$LogFolder = "$env:TEMP\CiscoLabLogs"
    )

    if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder | Out-Null }
    $logFile = Join-Path $LogFolder ("{0}-{1:yyyyMMdd_HHmmss}.log" -f $Host,(Get-Date))
    "=== {0} start {1} ===`r`n" -f $Host,(Get-Date) | Out-File -FilePath $logFile -Encoding UTF8

    $conn = $null
    try {
        Ensure-PoshSSH
        $conn = New-SSHShell -Host $Host -Credential $Credential -Port $Port
        $s = $conn.Stream

        $out = Wait-UntilPrompt -Stream $s
        $out += Send-CiscoCommand -Stream $s -Command "terminal length 0"
        $out | Out-File -FilePath $logFile -Append -Encoding UTF8

        if ($out -match "(?m)>") {
            $out2 = Send-CiscoCommand -Stream $s -Command "enable"
            if ($out2 -match "Password:") {
                if (-not $EnablePassword) { throw "Enable password benötigt für $Host." }
                $s.WriteLine($EnablePassword)
                $out2 += Wait-UntilPrompt -Stream $s
            }
            $out2 | Out-File -FilePath $logFile -Append -Encoding UTF8
        }

        $out3 = Send-CiscoCommand -Stream $s -Command "configure terminal"
        $out3 | Out-File -FilePath $logFile -Append -Encoding UTF8

        foreach ($line in $ConfigLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $resp = Send-CiscoCommand -Stream $s -Command $line
            $resp | Out-File -FilePath $logFile -Append -Encoding UTF8
        }

        $out4 = Send-CiscoCommand -Stream $s -Command "end"
        $out4 += Send-CiscoCommand -Stream $s -Command "write memory"
        $out4 | Out-File -FilePath $logFile -Append -Encoding UTF8

        Write-Host "[$Host] OK → $logFile" -ForegroundColor Green
        return $true
    } catch {
        $msg = "[$Host] FEHLER: $($_.Exception.Message)"
        Write-Warning $msg
        $msg | Out-File -FilePath $logFile -Append -Encoding UTF8
        return $false
    } finally {
        if ($conn) { try { if ($conn.Session) { Remove-SSHSession -SessionId $conn.Session.SessionId | Out-Null } } catch {} }
    }
}

# -------- Gerätespezifische Defaults (ISR 4321 / Cat 2960) --------

# Interfaces ISR 4321 (bei Bedarf anpassen)
$IF_R_MGMT = "GigabitEthernet0/0/0"   # MGMT zu SW1 (VLAN10)
$IF_R_P2P1 = "GigabitEthernet0/0/1"   # P2P-Link 1
$IF_R_P2P2 = "GigabitEthernet0/0/2"   # P2P-Link 2 (SFP – falls vorhanden; sonst anpassen)

# Access-Ports Catalyst 2960 (für MGMT-VLAN 10)
$IF_SW_ACCESS_RANGE = "FastEthernet0/1 - 0/4"

# Host-IP Mapping im Lab
$DeviceHosts = @{
    "R1" = "192.0.2.1"
    "R2" = "192.0.2.2"
    "R3" = "192.0.2.3"
    "SW1"= "192.0.2.10"
}

function Get-CiscoDeviceConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('router','switch')] [string]$Type,
        [Parameter(Mandatory=$false)][ValidateSet(1,2,3)] [int]$RouterNumber,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$UserSecret,
        [Parameter(Mandatory=$true)][string]$EnableSecret
    )

    if ($Type -eq 'router' -and -not $RouterNumber) { throw "RouterNumber 1/2/3 erforderlich." }

    # Passwort-/User-Block (gemeinsam)
    $SEC = @(
        "service password-encryption",
        "no ip domain-lookup",
        "ip domain-name lab.local",
        "enable secret $EnableSecret",
        "username $Username privilege 15 secret $UserSecret",
        "ip ssh version 2",
        "crypto key generate rsa modulus 2048",
        "line vty 0 4",
        " login local",
        " transport input ssh",
        " exec-timeout 10 0",
        " logging synchronous",
        "exit",
        "line con 0",
        " login local",
        " exec-timeout 10 0",
        " logging synchronous",
        "exit"
    )

    if ($Type -eq 'router') {
        switch ($RouterNumber) {
            1 {
                $host = $DeviceHosts["R1"]
                $lines = @(
                    "hostname R1"
                    $SEC
                    "interface $IF_R_MGMT"
                    " description MGMT to SW1 (VLAN10)"
                    " ip address 192.0.2.1 255.255.255.0"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P1"
                    " description P2P to R2"
                    " ip address 10.0.12.1 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P2"
                    " description P2P to R3"
                    " ip address 10.0.13.1 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface Loopback0"
                    " ip address 1.1.1.1 255.255.255.255"
                    "exit"
                    "router ospf 1"
                    " router-id 1.1.1.1"
                    " network 10.0.12.0 0.0.0.3 area 0"
                    " network 10.0.13.0 0.0.0.3 area 0"
                    " passive-interface $IF_R_MGMT"
                    "exit"
                )
            }
            2 {
                $host = $DeviceHosts["R2"]
                $lines = @(
                    "hostname R2"
                    $SEC
                    "interface $IF_R_MGMT"
                    " description MGMT to SW1 (VLAN10)"
                    " ip address 192.0.2.2 255.255.255.0"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P1"
                    " description P2P to R1"
                    " ip address 10.0.12.2 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P2"
                    " description P2P to R3"
                    " ip address 10.0.23.2 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface Loopback0"
                    " ip address 2.2.2.2 255.255.255.255"
                    "exit"
                    "router ospf 1"
                    " router-id 2.2.2.2"
                    " network 10.0.12.0 0.0.0.3 area 0"
                    " network 10.0.23.0 0.0.0.3 area 0"
                    " passive-interface $IF_R_MGMT"
                    "exit"
                )
            }
            3 {
                $host = $DeviceHosts["R3"]
                $lines = @(
                    "hostname R3"
                    $SEC
                    "interface $IF_R_MGMT"
                    " description MGMT to SW1 (VLAN10)"
                    " ip address 192.0.2.3 255.255.255.0"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P1"
                    " description P2P to R1"
                    " ip address 10.0.13.3 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface $IF_R_P2P2"
                    " description P2P to R2"
                    " ip address 10.0.23.3 255.255.255.252"
                    " no shutdown"
                    "exit"
                    "interface Loopback0"
                    " ip address 3.3.3.3 255.255.255.255"
                    "exit"
                    "router ospf 1"
                    " router-id 3.3.3.3"
                    " network 10.0.13.0 0.0.0.3 area 0"
                    " network 10.0.23.0 0.0.0.3 area 0"
                    " passive-interface $IF_R_MGMT"
                    "exit"
                )
            }
        }
        return [PSCustomObject]@{ Name = "R$RouterNumber"; Host = $host; Lines = $lines; Type = 'router' }
    }
    else { # switch
        $host = $DeviceHosts["SW1"]
        $lines = @(
            "hostname SW1",
            "service password-encryption",
            "no ip domain-lookup",
            "ip domain-name lab.local",
            "enable secret $EnableSecret",
            "username $Username privilege 15 secret $UserSecret",
            "vlan 10",
            " name MGMT",
            "exit",
            "interface Vlan10",
            " description Switch Management",
            " ip address 192.0.2.10 255.255.255.0",
            " no shutdown",
            "exit",
            "ip default-gateway 192.0.2.1",
            "crypto key generate rsa modulus 2048",
            "ip ssh version 2",
            "line vty 0 4",
            " login local",
            " transport input ssh",
            " exec-timeout 10 0",
            " logging synchronous",
            "exit",
            "line con 0",
            " login local",
            " exec-timeout 10 0",
            " logging synchronous",
            "exit",
            "interface range $IF_SW_ACCESS_RANGE",
            " switchport mode access",
            " switchport access vlan 10",
            " spanning-tree portfast",
            " description R1mgmt / R2mgmt / R3mgmt / PC",
            "exit"
        )
        return [PSCustomObject]@{ Name = "SW1"; Host = $host; Lines = $lines; Type = 'switch' }
    }
}

function Invoke-CiscoProvisionInteractive {
    [CmdletBinding()]
    param()

    Ensure-PoshSSH

    Write-Host "`n=== Cisco Provisioning (ISR 4321 / Catalyst 2960) ===" -ForegroundColor Cyan
    $type = Read-Host "Gerätetyp? (R=Router, S=Switch)"
    $typeNorm = if ($type -match '^[rR]') { 'router' } elseif ($type -match '^[sS]') { 'switch' } else { '' }
    if (-not $typeNorm) { Write-Warning "Ungueltige Auswahl"; return }

    $routerNo = $null
    if ($typeNorm -eq 'router') {
        $routerNo = Read-Host "Welcher Router? (1/2/3)"
        if ($routerNo -notmatch '^[123]$') { Write-Warning "Ungueltige Auswahl"; return }
        $routerNo = [int]$routerNo
    }

    $sshCred = Get-Credential -Message "SSH Login (vorhandener Account auf dem Gerät)"
    $userName = Read-Host "Lokaler Admin-User (neu/zu setzen) [Standard: admin]"
    if (-not $userName) { $userName = "admin" }
    $userPwdSec = Read-Host "Passwort für lokalen User" -AsSecureString
    $enSec      = Read-Host "Enable Secret" -AsSecureString

    $userPwd = Convert-SecureToPlain $userPwdSec
    $enPwd   = Convert-SecureToPlain $enSec

    $cfg = if ($typeNorm -eq 'router') {
        Get-CiscoDeviceConfig -Type router -RouterNumber $routerNo -Username $userName -UserSecret $userPwd -EnableSecret $enPwd
    } else {
        Get-CiscoDeviceConfig -Type switch -Username $userName -UserSecret $userPwd -EnableSecret $enPwd
    }

    $ok = Invoke-CiscoConfig -Host $cfg.Host -Credential $sshCred -ConfigLines $cfg.Lines -Port $SshPort
    if ($ok -and $typeNorm -eq 'router') {
        Write-Host "Hinweis: Prüfe OSPF-Nachbarn nach einigen Sekunden mit 'show ip ospf neighbor'." -ForegroundColor Yellow
    }
}
