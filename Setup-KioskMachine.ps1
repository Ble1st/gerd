<#
    Setup-KioskMachine.ps1

    Richtet einen Windows-Rechner als unbeaufsichtigte Wandanzeige ein.

    Das deckt die Punkte ab, die KEIN Skript zur Laufzeit abfangen kann: Wenn
    Windows den Bildschirm abschaltet, den Sperrbildschirm anzeigt oder nach
    einem Update-Neustart im Anmeldebildschirm stehen bleibt, nuetzt der
    schoenste Rundlauf nichts.

    Gesetzt werden:
      1) Energieoptionen - Bildschirm und Standby nie abschalten
      2) Kennwort bei Reaktivierung aus
      3) Bildschirmschoner aus
      4) Sperre bei Inaktivitaet aus (Computerinaktivitaetslimit = 0)
      5) Sperrbildschirm und Win+L deaktiviert
      6) Edge-Richtlinie gegen den Dialog "Seiten wiederherstellen?"
      7) Geplante Aufgabe fuer das Anzeigeskript
      8) Optional: naechtlicher Neustart
      9) Optional: automatische Anmeldung (siehe WARNUNG unten)

    STANDARDMAESSIG WIRD NICHTS GEAENDERT. Ohne -Apply laeuft das Skript als
    Trockenlauf und zeigt nur, was es tun wuerde.

    WARNUNG ZUR AUTOMATISCHEN ANMELDUNG:
      -EnableAutoLogon schreibt das Kennwort im KLARTEXT in die Registry
      (HKLM\...\Winlogon\DefaultPassword). Jeder, der den Rechner lesen kann,
      kann es dort auslesen. Der sauberere Weg ist Autologon.exe aus den
      Sysinternals Suite - das legt das Kennwort als LSA-Secret ab statt im
      Klartext. Deshalb ist der Schalter bewusst optional und nicht Teil des
      Standardlaufs.

    ZEITEN kommen aus .\config\settings.json, Abschnitt "kioskSetup", sofern
    vorhanden; die Parameter dieses Skripts ueberschreiben sie.

      "kioskSetup": {
        "taskIntervalMinutes": 5,
        "nightlyRebootTime": "04:30"
      }

    Aufruf:
      .\Setup-KioskMachine.ps1                       # Trockenlauf, zeigt alles
      .\Setup-KioskMachine.ps1 -Apply                # setzt alles ausser 8) und 9)
      .\Setup-KioskMachine.ps1 -Apply -NightlyReboot
      .\Setup-KioskMachine.ps1 -Apply -EnableAutoLogon -AutoLogonUser "kiosk"
#>

[CmdletBinding()]
Param(
    # Ohne diesen Schalter wird nichts veraendert.
    [Switch]$Apply,

    # Das Skript, das die Aufgabenplanung starten soll.
    [String]$ScriptPath = (Join-Path $PSScriptRoot "AppSupervisorAndBrowserCycle.ps1"),

    [String]$TaskName = "KioskDisplay",

    # Wie oft die Aufgabe anlaeuft. Laeuft das Skript noch, passiert nichts
    # (IgnoreNew) - stirbt es, ist die Anzeige nach spaetestens diesem
    # Intervall wieder da. 0 = aus der Konfiguration bzw. Standard 5.
    [int]$TaskIntervalMinutes = 0,

    [Switch]$NightlyReboot,
    [String]$NightlyRebootTime = "",

    [Switch]$EnableAutoLogon,
    [String]$AutoLogonUser = ""
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    Param(
        [Parameter(Mandatory = $true)][String]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','DRY')][String]$Level = 'INFO'
    )
    switch ($Level) {
        'OK'    { Write-Host "  [ok]   $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "  [warn] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [err]  $Message" -ForegroundColor Red }
        'DRY'   { Write-Host "  [dry]  $Message" -ForegroundColor Cyan }
        default { Write-Host "  $Message" }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RegistryValue {
    Param(
        [Parameter(Mandatory = $true)][String]$Path,
        [Parameter(Mandatory = $true)][String]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('String','DWord')][String]$Type = 'DWord',
        [Parameter(Mandatory = $true)][String]$Description
    )

    if (-Not $Apply) {
        Write-Step "$Description  ->  $Path\$Name = $Value" 'DRY'
        return
    }

    try {
        if (-Not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Step "$Description gesetzt." 'OK'
    }
    catch {
        Write-Step "$Description fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-PowerCfg {
    Param(
        [Parameter(Mandatory = $true)][String[]]$Arguments,
        [Parameter(Mandatory = $true)][String]$Description
    )

    if (-Not $Apply) {
        Write-Step "$Description  ->  powercfg $($Arguments -join ' ')" 'DRY'
        return
    }

    try {
        $output = & powercfg.exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Step "$Description meldete Exitcode $LASTEXITCODE : $output" 'WARN'
        }
        else {
            Write-Step "$Description gesetzt." 'OK'
        }
    }
    catch {
        Write-Step "$Description fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    }
}

# ============================================================
# Konfiguration einlesen (Zeiten), Parameter haben Vorrang
# ============================================================

$ConfigPath = Join-Path $PSScriptRoot "config\settings.json"
$KioskSetup = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $KioskSetup = (Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).kioskSetup
    }
    catch {
        Write-Step "settings.json konnte nicht gelesen werden, es gelten die Standardzeiten: $($_.Exception.Message)" 'WARN'
    }
}

if ($TaskIntervalMinutes -le 0) {
    $TaskIntervalMinutes = 5
    if ($KioskSetup.taskIntervalMinutes -and [int]$KioskSetup.taskIntervalMinutes -gt 0) {
        $TaskIntervalMinutes = [int]$KioskSetup.taskIntervalMinutes
    }
}

if ([string]::IsNullOrWhiteSpace($NightlyRebootTime)) {
    $NightlyRebootTime = "04:30"
    if ($KioskSetup.nightlyRebootTime) {
        $NightlyRebootTime = [String]$KioskSetup.nightlyRebootTime
    }
}

# ============================================================
# Vorbedingungen
# ============================================================

Write-Host ""
Write-Host "Setup-KioskMachine" -ForegroundColor White
Write-Host "==================" -ForegroundColor White

if (-Not (Test-IsAdministrator)) {
    Write-Step "Dieses Skript braucht lokale Administratorrechte (HKLM-Schluessel, Energieoptionen, Aufgabenplanung)." 'ERROR'
    Write-Step "PowerShell als Administrator starten und erneut ausfuehren." 'ERROR'
    return
}

if (-Not $Apply) {
    Write-Host ""
    Write-Step "TROCKENLAUF - es wird nichts veraendert. Mit -Apply ausfuehren, um die Aenderungen zu setzen." 'WARN'
}

Write-Host ""
Write-Host "Zeiten: Aufgabenintervall $TaskIntervalMinutes Minute(n), naechtlicher Neustart $NightlyRebootTime" -ForegroundColor White

# ============================================================
# 1) Energieoptionen
# ============================================================
Write-Host ""
Write-Host "1) Energieoptionen" -ForegroundColor White

# Netzbetrieb (ac) und Akku (dc) gleichermassen - ein Anzeige-PC haengt zwar
# am Netz, aber bei Mini-PCs mit Akku ist dc trotzdem wirksam.
foreach ($mode in @('ac','dc')) {
    Invoke-PowerCfg -Arguments @('/change', "monitor-timeout-$mode", '0')  -Description "Bildschirm-Timeout ($mode) aus"
    Invoke-PowerCfg -Arguments @('/change', "standby-timeout-$mode", '0')  -Description "Standby ($mode) aus"
    Invoke-PowerCfg -Arguments @('/change', "hibernate-timeout-$mode", '0') -Description "Ruhezustand ($mode) aus"
    Invoke-PowerCfg -Arguments @('/change', "disk-timeout-$mode", '0')     -Description "Festplatten-Timeout ($mode) aus"
}

# ============================================================
# 2) Kennwort bei Reaktivierung
# ============================================================
Write-Host ""
Write-Host "2) Kennwort bei Reaktivierung" -ForegroundColor White

Invoke-PowerCfg -Arguments @('/setacvalueindex','SCHEME_CURRENT','SUB_NONE','CONSOLELOCK','0') -Description "Kennwort bei Reaktivierung (Netz) aus"
Invoke-PowerCfg -Arguments @('/setdcvalueindex','SCHEME_CURRENT','SUB_NONE','CONSOLELOCK','0') -Description "Kennwort bei Reaktivierung (Akku) aus"
Invoke-PowerCfg -Arguments @('/setactive','SCHEME_CURRENT') -Description "Energieschema aktivieren"

# ============================================================
# 3) Bildschirmschoner
# ============================================================
Write-Host ""
Write-Host "3) Bildschirmschoner" -ForegroundColor White
Write-Step "Hinweis: Diese Werte liegen unter HKCU und gelten fuer das Konto, unter dem dieses Skript laeuft." 'WARN'

Set-RegistryValue -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive"   -Value "0" -Type String -Description "Bildschirmschoner aus"
Set-RegistryValue -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveTimeOut"  -Value "0" -Type String -Description "Bildschirmschoner-Timeout auf 0"
Set-RegistryValue -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0" -Type String -Description "Kennwortschutz des Bildschirmschoners aus"

# ============================================================
# 4) Sperre bei Inaktivitaet
# ============================================================
Write-Host ""
Write-Host "4) Sperre bei Inaktivitaet" -ForegroundColor White

Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "InactivityTimeoutSecs" -Value 0 -Description "Computerinaktivitaetslimit auf 0 (nie sperren)"

# ============================================================
# 5) Sperrbildschirm
# ============================================================
Write-Host ""
Write-Host "5) Sperrbildschirm" -ForegroundColor White

Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1 -Description "Sperrbildschirm nicht anzeigen"
Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableLockWorkstation" -Value 1 -Description "Sperren per Win+L unterbinden"

# ============================================================
# 6) Edge-Richtlinie
# ============================================================
Write-Host ""
Write-Host "6) Edge-Richtlinie" -ForegroundColor White

Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "HideRestoreDialogEnabled" -Value 1 -Description "Dialog 'Seiten wiederherstellen?' unterdruecken"

# ============================================================
# 7) Geplante Aufgabe
# ============================================================
Write-Host ""
Write-Host "7) Geplante Aufgabe '$TaskName'" -ForegroundColor White

if (-Not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Step "Das Anzeigeskript wurde nicht gefunden: $ScriptPath" 'ERROR'
    Write-Step "Mit -ScriptPath den richtigen Pfad angeben." 'ERROR'
}
else {
    $taskUser = "$env:USERDOMAIN\$env:USERNAME"

    if (-Not $Apply) {
        Write-Step "Aufgabe '$TaskName' anlegen: $ScriptPath" 'DRY'
        Write-Step "  Konto $taskUser, hoechste Rechte, Start bei Anmeldung" 'DRY'
        Write-Step "  Wiederholung alle $TaskIntervalMinutes Minute(n), keine zweite Instanz" 'DRY'
    }
    else {
        try {
            $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

            # Start bei der Anmeldung, danach in festem Takt wiederholen. Die
            # Wiederholung ist die eigentliche Selbstheilung: RestartCount in
            # der Aufgabenplanung greift nur bei fehlgeschlagenen STARTS -
            # wird der laufende Prozess abgeschossen, geht die Aufgabe auf
            # "Bereit" und wartet stumm auf den naechsten Trigger.
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
            $repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Minutes $TaskIntervalMinutes) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
            $trigger.Repetition = $repeat.Repetition

            # Interactive: Die Aufgabe MUSS in der angemeldeten Sitzung
            # laufen. "Unabhaengig von der Benutzeranmeldung" wuerde sie ohne
            # Desktop starten - Fensteraktivierung und Tastendruecke gingen
            # dann ins Leere.
            $principal = New-ScheduledTaskPrincipal -UserId $taskUser `
                -LogonType Interactive -RunLevel Highest

            $settings = New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -StartWhenAvailable

            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null

            Write-Step "Aufgabe '$TaskName' angelegt (alle $TaskIntervalMinutes Minute(n), keine zweite Instanz)." 'OK'
        }
        catch {
            Write-Step "Aufgabe konnte nicht angelegt werden: $($_.Exception.Message)" 'ERROR'
        }
    }
}

# ============================================================
# 8) Naechtlicher Neustart (optional)
# ============================================================
Write-Host ""
Write-Host "8) Naechtlicher Neustart" -ForegroundColor White

if (-Not $NightlyReboot) {
    Write-Step "Nicht angefordert - mit -NightlyReboot aktivieren. Ein taeglicher Neustart raeumt Speicherlecks von Edge und dem Videoclient auf."
}
elseif (-Not $Apply) {
    Write-Step "Aufgabe '$TaskName-Reboot' taeglich um $NightlyRebootTime anlegen" 'DRY'
}
else {
    try {
        $rebootAction  = New-ScheduledTaskAction -Execute "shutdown.exe" `
            -Argument "/r /t 60 /c ""Geplanter naechtlicher Neustart der Anzeige"""
        $rebootTrigger = New-ScheduledTaskTrigger -Daily -At $NightlyRebootTime
        $rebootPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
            -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName "$TaskName-Reboot" -Action $rebootAction `
            -Trigger $rebootTrigger -Principal $rebootPrincipal -Force | Out-Null

        Write-Step "Neustart-Aufgabe angelegt (taeglich $NightlyRebootTime)." 'OK'
    }
    catch {
        Write-Step "Neustart-Aufgabe konnte nicht angelegt werden: $($_.Exception.Message)" 'ERROR'
    }
}

# ============================================================
# 9) Automatische Anmeldung (optional)
# ============================================================
Write-Host ""
Write-Host "9) Automatische Anmeldung" -ForegroundColor White

if (-Not $EnableAutoLogon) {
    Write-Step "Nicht angefordert. Ohne automatische Anmeldung steht nach einem Update-Neustart der Anmeldebildschirm auf der Wand."
    Write-Step "Empfehlung: Autologon.exe aus den Sysinternals verwenden - das legt das Kennwort als LSA-Secret ab statt im Klartext."
    Write-Step "Wer es trotzdem hier will: -EnableAutoLogon -AutoLogonUser '<Konto>'"
}
else {
    Write-Step "Die automatische Anmeldung speichert das Kennwort im KLARTEXT in der Registry. Jeder mit Lesezugriff auf den Rechner kann es auslesen." 'WARN'

    if ([string]::IsNullOrWhiteSpace($AutoLogonUser)) {
        Write-Step "Es wurde kein -AutoLogonUser angegeben - uebersprungen." 'ERROR'
    }
    elseif (-Not $Apply) {
        Write-Step "Automatische Anmeldung fuer '$AutoLogonUser' einrichten (Kennwortabfrage beim Ausfuehren)" 'DRY'
    }
    else {
        $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $secure = Read-Host -Prompt "Kennwort fuer '$AutoLogonUser'" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

        if ([string]::IsNullOrEmpty($plain)) {
            Write-Step "Kein Kennwort eingegeben - uebersprungen." 'ERROR'
        }
        else {
            Set-RegistryValue -Path $winlogon -Name "AutoAdminLogon"  -Value "1"             -Type String -Description "Automatische Anmeldung aktivieren"
            Set-RegistryValue -Path $winlogon -Name "DefaultUserName" -Value $AutoLogonUser  -Type String -Description "Anmeldekonto"
            Set-RegistryValue -Path $winlogon -Name "DefaultPassword" -Value $plain          -Type String -Description "Anmeldekennwort (Klartext)"
            Set-RegistryValue -Path $winlogon -Name "DefaultDomainName" -Value $env:USERDOMAIN -Type String -Description "Anmeldedomaene"
            Write-Step "Kennwort liegt jetzt im Klartext unter $winlogon\DefaultPassword." 'WARN'
        }
    }
}

# ============================================================
Write-Host ""
Write-Host "Fertig." -ForegroundColor White
if (-Not $Apply) {
    Write-Host "Es wurde nichts veraendert (Trockenlauf). Mit -Apply erneut ausfuehren." -ForegroundColor Yellow
}
else {
    Write-Host "Die Registry-Aenderungen greifen teils erst nach Ab- und Anmelden oder einem Neustart." -ForegroundColor Yellow
}
Write-Host ""
