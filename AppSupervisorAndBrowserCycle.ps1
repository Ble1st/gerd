<#
    AppSupervisorAndBrowserCycle.ps1

    Kombiniertes Skript aus:
      - Switcher.ps1       -> Prozess-Ueberwachung (Apps neu starten, falls nicht laufend)
      - BrowserCycle.ps1   -> Browser-Tabs oeffnen, ggf. einloggen, im Kreis durchschalten

    AENDERUNGEN (2026-09-16):
      1) Ueberwachte Programme sind jetzt fest auf Notepad++ und HD Witness begrenzt
         (Default-Konfiguration). SDR Console / ProScan / PDW wurden entfernt.
      2) Echte Prozess-Pruefung: Es wird nicht mehr nur der (frei waehlbare) "Name"
         aus settings.json mit Get-Process abgeglichen, sondern zusaetzlich der
         tatsaechliche EXE-Dateiname aus dem konfigurierten Pfad UND - wo moeglich -
         der volle Pfad des laufenden Prozesses (Get-Process -> Path). Dadurch wird
         verhindert, dass Programme faelschlich als "nicht laufend" erkannt und
         wiederholt neu gestartet werden (Bug im Log: HD Witness wurde 4x in 90s
         neu gestartet, weil "Name" != tatsaechlicher Prozessname war).
      3) Browser-Cycle prueft jetzt VOR dem Oeffnen eines neuen Fensters, ob bereits
         ein Edge-Prozess laeuft. Es wird sichergestellt, dass am Ende genau EIN
         Edge-Fenster mit den konfigurierten Tabs offen ist. Ueberzaehlige
         Edge-Fenster/Prozesse werden erkannt, geloggt und (konfigurierbar)
         geschlossen, damit nicht mehrere Browserfenster parallel offen bleiben.
      4) Vollbild-Rundlauf (Invoke-FullscreenCycle). Nach dem konfigurierbaren
         Intervall "fullscreenCycleIntervalSeconds" (Sekunden) wird reihum JEDES
         referenzierte Browserfenster (Tabs aus browserCycle) UND JEDES ueberwachte
         Programm (monitoredApps, also Notepad++ und HD Witness) in den Vordergrund
         geholt und in den Vollbildmodus (F11) versetzt.
         FIX (2026-09-16): Vorher wurde SetForegroundWindow/AppActivate NIE auf
         tatsaechlichen Erfolg geprueft - bei Programmen, die mit hoeheren Rechten
         laufen als das Skript (z.B. HD Witness, falls erhoeht/als Administrator
         gestartet), schlaegt die Fokus-Uebernahme wegen Windows' Focus-Stealing-
         Schutz (UIPI) lautlos fehl. F11 wurde dann "blind" gesendet und landete im
         FALSCHEN (tatsaechlich noch aktiven) Fenster - dadurch erschien HD Witness
         im Log als "aktiviert", war aber visuell nicht im Vordergrund/Vollbild.
         Jetzt wird per GetForegroundWindow ECHT verifiziert, ob das Zielfenster im
         Vordergrund ist; F11 wird nur bei bestaetigtem Erfolg gesendet, sonst gibt
         es eine klare WARN-Meldung inkl. Hinweis auf ggf. fehlende Admin-Rechte.
         SICHERHEITS-HARDSTOP: Zur Absicherung ist der komplette Vollbild-Rundlauf
         aktuell hart auf maximal 2 Minuten Gesamtlaufzeit begrenzt (Konstante
         $HardStopFullscreenCycleSeconds), UNABHAENGIG von der Konfiguration. Das
         verhindert, dass der Vollbild-Wechsel bei Fehlkonfiguration endlos/zu lange
         laeuft, bevor es im produktiven Dauerbetrieb final freigegeben wird.

    Konfiguration liegt in:
        .\config\settings.json

    Struktur von config\settings.json:
    {
      "monitoredApps": [
        { "Name": "Notepad++", "Path": "C:\\Program Files\\Notepad++\\notepad++.exe" },
        { "Name": "HD Witness", "Path": "C:\\Program Files\\Network Optix\\Nx Witness\\Client\\6.1.2.42921\\HD Witness.exe" }
      ],
      "browserCycle": {
        "waitSeconds": 30,
        "closeExtraBrowserWindows": true,
        "fullscreenCycleIntervalSeconds": 60,
        "tabs": [
          {
            "Active": true,
            "Name": "Beispiel",
            "URL": "https://...",
            "TabName": "*Dashboard*",
            "ThisIsUnsafe": false,
            "TabNameUnsafe": "",
            "Login": false,
            "TabNameLogin": "",
            "Username": "",
            "Pw": ""
          }
        ]
      }
    }
#>

# ============================================================
# Konfiguration laden (Unterordner + settings.json werden beim
# ersten Start automatisch angelegt, falls sie fehlen)
# ============================================================

$ConfigDir  = Join-Path $PSScriptRoot "config"
$ConfigPath = Join-Path $ConfigDir "settings.json"

# ============================================================
# Einfaches File-Logging (Unterordner .\log)
# ============================================================
$LogDir  = Join-Path $PSScriptRoot "log"
if (-Not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("AppSupervisorAndBrowserCycle_" + (Get-Date -Format "yyyyMMdd") + ".log")

# ============================================================
# Persistenter State fuer bereits geoeffnete Browser-Tabs
# (verhindert doppelte Tabs, wenn der Fenstertitel-Match wegen
#  einer generischen/uneindeutigen TabName-Wildcard fehlschlaegt,
#  z.B. bei Platzhalter-URLs wie https://example.com/dashboard,
#  deren echter Seitentitel nicht zum konfigurierten TabName passt)
# ============================================================
$StateDir  = Join-Path $PSScriptRoot "state"
if (-Not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}
$OpenedTabsStateFile = Join-Path $StateDir "opened_tabs.json"

function Get-OpenedTabsState {
    <#
        Liest den State bereits geoeffneter Tabs ein.
        Struktur: @{ "<Name>" = @{ URL = "..."; OpenedAt = "..."; EdgePid = 1234 } }
        Eintraege werden verworfen, sobald der zugehoerige Edge-Prozess (PID)
        nicht mehr existiert - d.h. nach einem Neustart/Schliessen von Edge
        gilt automatisch wieder "kein Tab offen".
    #>
    if (-Not (Test-Path -LiteralPath $OpenedTabsStateFile)) {
        return @{}
    }
    try {
        $raw = Get-Content -Path $OpenedTabsStateFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "State-Datei '$OpenedTabsStateFile' war ungueltig und wird zurueckgesetzt." 'WARN'
        return @{}
    }

    $result = @{}
    if ($raw) {
        foreach ($prop in $raw.PSObject.Properties) {
            $entry = $prop.Value
            $pidStillRunning = $false
            try {
                if ($entry.EdgePid) {
                    $p = Get-Process -Id $entry.EdgePid -ErrorAction SilentlyContinue
                    if ($p -and $p.ProcessName -eq 'msedge') { $pidStillRunning = $true }
                }
            } catch { $pidStillRunning = $false }

            if ($pidStillRunning) {
                $result[$prop.Name] = $entry
            }
        }
    }
    return $result
}

function Save-OpenedTabsState {
    Param(
        [Parameter(Mandatory = $true)]
        [Hashtable]$State
    )
    try {
        $State | ConvertTo-Json -Depth 4 | Set-Content -Path $OpenedTabsStateFile -Encoding UTF8
    }
    catch {
        Write-Log "State-Datei konnte nicht geschrieben werden: $($_.Exception.Message)" 'WARN'
    }
}

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)][String]$Message,
        [ValidateSet('INFO','WARN','ERROR')][String]$Level = 'INFO'
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"

    # In Datei schreiben (robust, ohne Abbruch bei Schreibfehlern)
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Wenn Log-Datei nicht beschreibbar ist, zumindest Konsole
    }

    # Konsole
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}


function New-DefaultSettings {
    Param(
        [Parameter(Mandatory = $true)]
        [String]$Path
    )

    # Nur noch Notepad++ und HD Witness als Standard-ueberwachte Programme
    $defaultSettings = [ordered]@{
        monitoredApps = @(
            [ordered]@{ Name = "Notepad++";  Path = "C:\Program Files\Notepad++\notepad++.exe" }
            [ordered]@{ Name = "HD Witness"; Path = "C:\Program Files\Network Optix\Nx Witness\Client\6.1.2.42921\HD Witness.exe" }
        )
        browserCycle  = [ordered]@{
            waitSeconds                     = 30
            closeExtraBrowserWindows        = $true
            fullscreenCycleIntervalSeconds  = 60
            tabs                            = @(
                [ordered]@{
                    Active        = $true
                    Name          = "Beispiel Dashboard"
                    URL           = "https://example.com/dashboard"
                    TabName       = "*Dashboard*"
                    ThisIsUnsafe  = $false
                    TabNameUnsafe = ""
                    Login         = $false
                    TabNameLogin  = ""
                    Username      = ""
                    Pw            = ""
                }
            )
        }
    }

    $defaultSettings | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

# Unterordner "config" anlegen, falls nicht vorhanden
if (-Not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    Write-Log "Ordner 'config' wurde erstellt: $ConfigDir"
}

# settings.json mit Standardwerten anlegen, falls nicht vorhanden
if (-Not (Test-Path $ConfigPath)) {
    New-DefaultSettings -Path $ConfigPath
    Write-Log "Es wurde keine settings.json gefunden. Eine Standardkonfiguration wurde erstellt: $ConfigPath"
    Write-Log "Bitte die Werte (Apps, URLs, Zugangsdaten etc.) vor dem produktiven Einsatz anpassen."
}

try {
    $Settings = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "FEHLER: Die Datei '$ConfigPath' enthaelt ungueltiges JSON und konnte nicht gelesen werden." -ForegroundColor Red
    Write-Host "Haeufigste Ursache: Windows-Pfade mit einfachen Backslashes, z.B. `"C:\Program Files\App`"." -ForegroundColor Yellow
    Write-Host "In JSON muessen Backslashes VERDOPPELT werden, z.B. `"C:\\Program Files\\App\\App.exe`"." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Original-Fehlermeldung:" -ForegroundColor Yellow
    Write-Host $_.Exception.Message
    throw "Abbruch: settings.json ist ungueltig. Bitte Pfade pruefen (doppelte Backslashes) und erneut starten."
}

# ------------------------------------------------------------
# Harte Begrenzung auf die gewuenschten Programme:
# Es werden ausschliesslich "Notepad++" und "HD Witness" ueberwacht,
# unabhaengig davon, was zusaetzlich (noch) in settings.json steht.
# So bleibt settings.json kompatibel/erweiterbar, aber es werden
# keine anderen Programme mehr automatisch gestartet.
# ------------------------------------------------------------
$AllowedAppNames = @('Notepad++', 'HD Witness')

if ($Settings.monitoredApps) {
    $FilteredApps = @($Settings.monitoredApps | Where-Object { $AllowedAppNames -contains $_.Name })

    $IgnoredApps = @($Settings.monitoredApps | Where-Object { $AllowedAppNames -notcontains $_.Name })
    foreach ($ignored in $IgnoredApps) {
        Write-Log "App '$($ignored.Name)' steht in settings.json, wird aber gemaess Vorgabe NICHT mehr ueberwacht (nur Notepad++ und HD Witness sind erlaubt)." 'WARN'
    }

    $Settings.monitoredApps = $FilteredApps
}

# Event-Log-Quelle registrieren, falls moeglich (erfordert lokale Admin-Rechte).
# WICHTIG: SourceExists kann bei fehlenden Rechten eine SecurityException werfen.
# Deshalb wird das komplett abgefangen und das Script laeuft ohne EventLog weiter.
$script:EventLogAvailable = $false
try {
    if ([System.Diagnostics.EventLog]::SourceExists("sdr-supervisor")) {
        $script:EventLogAvailable = $true
    }
    else {
        try {
            [System.Diagnostics.EventLog]::CreateEventSource("sdr-supervisor", "Application")
            $script:EventLogAvailable = $true
        }
        catch {
            Write-Log "Windows Event Log Quelle konnte nicht angelegt werden (keine Adminrechte): $($_.Exception.Message)" 'WARN'
        }
    }
}
catch {
    Write-Log "Windows Event Log nicht nutzbar (SecurityException/keine Rechte): $($_.Exception.Message)" 'WARN'
    $script:EventLogAvailable = $false
}


# ============================================================
# TEIL 1: Prozess-Ueberwachung (ehemals Switcher.ps1)
# ============================================================

function Test-AppIsRunning {
    <#
        Echte Pruefung, ob ein Programm bereits laeuft.

        Statt sich nur auf den frei waehlbaren "Name" aus settings.json zu
        verlassen (der oft NICHT mit dem tatsaechlichen Windows-Prozessnamen
        uebereinstimmt, z.B. bei Nx Witness/HD Witness), wird:

          1) der Datei-Basisname aus dem konfigurierten Pfad ermittelt
             (z.B. "HD Witness.exe" -> Prozessname "HD Witness")
          2) ueber Get-Process nach genau diesem Prozessnamen gesucht
          3) zusaetzlich - wo verfuegbar - der volle Pfad (Path-Property)
             des laufenden Prozesses mit dem konfigurierten Pfad
             verglichen, um Verwechslungen bei gleichnamigen Prozessen
             auszuschliessen.

        Liefert $true zurueck, sobald mindestens ein Prozess gefunden wird,
        dessen Name ODER Pfad zur Konfiguration passt.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [String]$ConfiguredPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return $false
    }

    $expectedProcessName = [System.IO.Path]::GetFileNameWithoutExtension($ConfiguredPath)

    # Kandidaten ueber den aus dem Pfad abgeleiteten Prozessnamen suchen
    $candidates = Get-Process -Name $expectedProcessName -ErrorAction SilentlyContinue

    if (-Not $candidates) {
        return $false
    }

    # Wenn wir den Pfad des laufenden Prozesses auslesen koennen, zusaetzlich
    # gegen den konfigurierten Pfad validieren (robuster, verhindert False
    # Positives bei zufaelligen Namensgleichheiten). Falls der Pfad aus
    # Rechtegruenden nicht lesbar ist (Access Denied), zaehlt der reine
    # Namenstreffer trotzdem als "laeuft".
    foreach ($proc in $candidates) {
        try {
            if ($proc.Path -and (Test-Path -LiteralPath $proc.Path)) {
                if ($proc.Path -ieq $ConfiguredPath) {
                    return $true
                }
            }
            else {
                # Pfad nicht auslesbar -> Namenstreffer reicht als Nachweis
                return $true
            }
        }
        catch {
            # Zugriff auf Path verweigert (z.B. andere Rechte) -> Namenstreffer reicht
            return $true
        }
    }

    # Es gab Namenstreffer, aber keiner hatte den passenden Pfad
    return $false
}

function Invoke-AppSupervisor {
    Param(
        [Parameter(Mandatory = $true)]
        [Object[]]$MonitoredApps
    )

    # Sleep momentarily in case the crashed application is lingering
    Start-Sleep -Seconds 1.0

    $started_processes = @()

    foreach ($app in $MonitoredApps) {

        $isRunning = Test-AppIsRunning -ConfiguredPath $app.Path

        if (-Not $isRunning) {
            if (-Not (Test-Path -LiteralPath $app.Path -PathType Leaf)) {
                Write-Log "Pfad fuer '$($app.Name)' zeigt nicht auf eine ausfuehrbare Datei: $($app.Path)" 'WARN'
                Write-Log "Bitte in config\settings.json den vollstaendigen Pfad inkl. .exe-Dateiname eintragen." 'WARN'
                continue
            }
            try {
                $started_processes += Start-Process -FilePath "$($app.Path)" -PassThru -ErrorAction Stop
                Write-Log "'$($app.Name)' war nicht aktiv (echte Prozesspruefung negativ) - wurde neu gestartet." 'INFO'
            }
            catch {
                Write-Log "'$($app.Name)' konnte nicht gestartet werden: $($_.Exception.Message)" 'WARN'
            }
        }
        else {
            Write-Log "'$($app.Name)' laeuft bereits (echte Prozesspruefung positiv) - kein Neustart noetig."
        }
    }

    foreach ($process in $started_processes) {
        $msg = "Started application '$($process.Name)' ($($process.Path)) as it was not running."
        Write-Log $msg
        if ($script:EventLogAvailable) {
        try {
            Write-EventLog -LogName Application -Source sdr-supervisor -EntryType Information -Category 0 -EventId 1 -Message $msg -ErrorAction Stop
        }
        catch {
            Write-Log "Eintrag im Windows Event Log nicht moeglich: $($_.Exception.Message)" 'WARN'
        }
    }
    }

    if ($started_processes.Count -eq 0) {
        $appNames = ($MonitoredApps | ForEach-Object { $_.Name }) -Join ', '
        $msg = "All expected applications are running ($appNames)"
        Write-Log $msg
        if ($script:EventLogAvailable) {
        try {
            Write-EventLog -LogName Application -Source sdr-supervisor -EntryType Information -Category 0 -EventId 0 -Message $msg -ErrorAction Stop
        }
        catch {
            Write-Log "Eintrag im Windows Event Log nicht moeglich: $($_.Exception.Message)" 'WARN'
        }
    }
    }
}


# ============================================================
# TEIL 2: Browser-Cycle (ehemals BrowserCycle.ps1)
# ============================================================

function Get-BrowserProcessCount {
    <# Liefert die Anzahl aktuell laufender Edge-Prozesse zurueck (alle Hintergrundprozesse). #>
    return @(Get-Process -Name "msedge" -ErrorAction SilentlyContinue).Count
}

function Get-EdgeWindowProcesses {
    <# Liefert nur die Edge-Prozesse, die ein sichtbares Top-Level-Fenster mit Titel besitzen. #>
    return @(Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -ne "" })
}

function Open-UrlInExistingWindow {
    <#
        Oeffnet eine URL als NEUEN TAB in einem bereits vorhandenen Edge-Fenster,
        OHNE einen neuen Prozess/ein neues Fenster zu starten.

        Vorgehen: Bestehendes Edge-Fenster in den Vordergrund holen, neuen Tab per
        Tastenkombination (Strg+T) oeffnen, URL eintippen und mit Enter bestaetigen.
        Das ist die einzige zuverlaessige Methode, einen Tab OHNE neues Fenster zu
        erzeugen - jeder "Start-Process msedge.exe <URL>"-Aufruf startet naemlich
        technisch einen neuen Edge-Prozessaufruf und fuehrt bei wiederholter
        Skriptausfuehrung genau zu dem beobachteten Fehler (bei jedem Lauf ein
        zusaetzlicher Tab/ein zusaetzliches Fenster).
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$ExistingWindowProcess,
        [Parameter(Mandatory = $true)]
        [String]$URL
    )

    if (-Not ([System.Management.Automation.PSTypeName]'Program').Type) {
        Add-Type "using System;using System.Runtime.InteropServices;public class Program {[DllImport(`"user32.dll`")][return: MarshalAs(UnmanagedType.Bool)]public static extern bool SetForegroundWindow(IntPtr hWnd);}"
    }

    [Program]::SetForegroundWindow($ExistingWindowProcess.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 500

    $wshell = New-Object -ComObject wscript.shell
    $activated = $false
    $tries = 0
    while (-not $activated -and $tries -lt 10) {
        $activated = $wshell.AppActivate($ExistingWindowProcess.Id)
        if (-not $activated) { Start-Sleep -Milliseconds 300 }
        $tries++
    }

    # Neuen Tab oeffnen (Strg+T), URL eintippen, Enter
    $wshell.SendKeys('^t')
    Start-Sleep -Milliseconds 500
    $wshell.SendKeys($URL)
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys('{ENTER}')
    Start-Sleep -Seconds 1
}

function Assert-SingleBrowserWindow {
    <#
        Echte Pruefung, dass am Ende genau EIN Browser-Fenster mit den
        gewuenschten Tabs offen ist:

          - Ermittelt alle Edge-Prozesse mit sichtbarem Top-Level-Fenster
            (Edge startet i.d.R. mehrere Hintergrundprozesse ohne eigenes
            Fenster - die werden hier bewusst nicht mitgezaehlt).
          - Wenn mehr als ein Fenster mit nicht-leerem Titel existiert und
            $CloseExtra = $true, werden die zusaetzlichen Fenster (Prozesse)
            beendet, sodass nur das aelteste (zuerst gestartete) bestehen
            bleibt.
          - Loggt in jedem Fall das Ergebnis der Pruefung.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Bool]$CloseExtra
    )

    $edgeProcesses = Get-EdgeWindowProcesses
    $windowCount = $edgeProcesses.Count

    if ($windowCount -le 1) {
        Write-Log "Browser-Pruefung: $windowCount sichtbares Edge-Fenster gefunden - Vorgabe (genau 1 Fenster) erfuellt."
        return
    }

    Write-Log "Browser-Pruefung: $windowCount sichtbare Edge-Fenster gefunden, erwartet wird genau 1 Fenster." 'WARN'

    if (-Not $CloseExtra) {
        Write-Log "closeExtraBrowserWindows ist deaktiviert - ueberzaehlige Fenster werden NICHT automatisch geschlossen." 'WARN'
        return
    }

    # Das Fenster mit der laengsten Laufzeit (aeltester Prozess) behalten,
    # alle anderen sichtbaren Edge-Fenster schliessen.
    $sorted = $edgeProcesses | Sort-Object StartTime
    $keep   = $sorted | Select-Object -First 1
    $toClose = $sorted | Select-Object -Skip 1

    foreach ($proc in $toClose) {
        try {
            Write-Log "Schliesse zusaetzliches Edge-Fenster (PID $($proc.Id), Titel '$($proc.MainWindowTitle)'), um nur ein Browserfenster offen zu halten." 'WARN'
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Konnte zusaetzliches Edge-Fenster (PID $($proc.Id)) nicht schliessen: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log "Browser-Pruefung abgeschlossen: 1 Fenster behalten (PID $($keep.Id)), $($toClose.Count) weitere(s) geschlossen."
}

function OpenUrlAndLogin {
    Param(
        [Parameter(Mandatory = $true)]
        [String]$Name,
        [Parameter(Mandatory = $true)]
        [String]$URL,
        [Parameter(Mandatory = $true)]
        [String]$TabName,

        [Parameter(Mandatory = $true)]
        [Bool]$ThisIsUnsafe,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String]$TabNameUnsafe,

        [Parameter(Mandatory = $true)]
        [Bool]$Login,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String]$TabNameLogin,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String]$Username,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String]$Pw,

        [Parameter(Mandatory = $true)]
        [Hashtable]$OpenedTabsState
    )
    <#
        Mehrstufige, ROBUSTE Pruefung, ob der Tab schon offen ist - erst wenn
        ALLE Stufen negativ sind, wird ein Tab neu erzeugt:

          Stufe 1 (State-Datei): Wurde fuer "$Name" bereits ein Tab in DIESEM
                    noch laufenden Edge-Prozess (gleiche PID) geoeffnet?
                    -> Das ist der zuverlaessigste Check, unabhaengig vom
                       Fenstertitel. Loest das Problem bei Platzhalter-URLs
                       wie https://example.com/dashboard, deren echter
                       Seitentitel NICHT zur konfigurierten TabName-Wildcard
                       passt (z.B. TabName "*Dashboard*", echter Titel aber
                       "Example Domain") - vorher fuehrte das dazu, dass bei
                       JEDEM Lauf ein weiterer Tab aufgemacht wurde.
          Stufe 2 (Fenstertitel): Zusaetzlich klassischer Titel-Match ueber
                    FindByName, falls TabName korrekt gepflegt ist.

        Nur wenn beide Stufen keinen Treffer liefern, wird ein Tab geoeffnet:
          - Existiert bereits ein Edge-Fenster -> Tab dort erzeugen (kein
            neuer Prozess/kein neues Fenster).
          - Kein Edge-Fenster aktiv -> neues Fenster.

        Nach dem Oeffnen wird der Treffer in $OpenedTabsState (Name -> URL,
        EdgePid, OpenedAt) vermerkt, damit der naechste Lauf den Tab sicher
        wiedererkennt, selbst wenn der Fenstertitel nicht matched.

        return Process Object
    #>
    $ps = $null
    $count = 0

    # ---- Stufe 1: State-Datei pruefen -------------------------------------
    if ($OpenedTabsState.ContainsKey($Name)) {
        $stateEntry = $OpenedTabsState[$Name]
        $edgeStillRunning = Get-Process -Id $stateEntry.EdgePid -ErrorAction SilentlyContinue
        if ($edgeStillRunning -and $edgeStillRunning.ProcessName -eq 'msedge' -and $stateEntry.URL -eq $URL) {
            Write-Log "Tab fuer '$Name' wurde in dieser Sitzung bereits geoeffnet (State-Pruefung, PID $($stateEntry.EdgePid)) - es wird NICHTS neu geoeffnet."
            # Versuchen, das zugehoerige Fenster fuer den Rueckgabewert zu liefern (fuer CicleTabs)
            $ps = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $stateEntry.EdgePid }
            if (-Not $ps) {
                $ps = Get-EdgeWindowProcesses | Select-Object -First 1
            }
            return($ps)
        }
        else {
            Write-Log "State-Eintrag fuer '$Name' ist nicht mehr gueltig (Edge-Prozess beendet oder URL geaendert) - Tab wird neu geprueft/geoeffnet." 'WARN'
        }
    }

    # ---- Stufe 2: Klassischer Fenstertitel-Match --------------------------
    $ps = FindByName($TabName)

    if ($ps.MainWindowHandle -ne $null -and $ps.Id -ne $null) {
        Write-Log "Tab/Fenster fuer '$Name' existiert bereits (Titel-Match auf '$TabName') - es wird NICHTS neu geoeffnet (verhindert doppelte Tabs bei jedem Skriptlauf)."
        $OpenedTabsState[$Name] = @{ URL = $URL; OpenedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); EdgePid = $ps.Id }
        Save-OpenedTabsState -State $OpenedTabsState
        return($ps)
    }

    #Kein passender Tab gefunden -> pruefen, ob ueberhaupt schon ein Edge-Fenster offen ist
    $existingWindows = Get-EdgeWindowProcesses
    $targetEdgePid = $null

    if ($existingWindows.Count -gt 0) {
        $targetWindow = $existingWindows | Select-Object -First 1
        $targetEdgePid = $targetWindow.Id
        Write-Log "Tab '$Name' nicht gefunden (weder per State noch per Titel-Match auf '$TabName'), Edge laeuft bereits (PID $($targetWindow.Id)). Oeffne Tab IM BESTEHENDEN Fenster (kein neues Fenster/keine neue Instanz)."
        Write-Log "Hinweis: Falls der Titel-Match dauerhaft fehlschlaegt, TabName in settings.json pruefen (muss zum tatsaechlichen Seitentitel passen, z.B. '*Example Domain*' statt '*Dashboard*' bei einer Test-URL)." 'WARN'
        Open-UrlInExistingWindow -ExistingWindowProcess $targetWindow -URL $URL
    }
    else {
        Write-Log "Kein Edge-Fenster aktiv. Oeffne neues Fenster fuer '$Name'."
        Start-Process -FilePath "msedge.exe" -ArgumentList "--new-window --lanf=de-DE $URL"
    }

    $count = 0
    #get process id with window title
    do {
        if ($count -eq 10) {
            break
        }

        if ($ThisIsUnsafe) {
            $ps = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -like $TabNameUnsafe
        }
        elseif ($Login) {
            $ps = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -like $TabNameLogin
        }
        else {
            $ps = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -like $TabName
        }
        Start-Sleep -Seconds 1
        $count++
    }while ($ps.Id -eq $null)

    if ($ps.Id -ne $null) {
        #This is Unsafe
        Write-Host $Name 'Check for Unsafe' $ThisIsUnsafe;
        if ($ThisIsUnsafe) {
            ThisIsUnsafe -Ps $ps
            # Nach dem Ueberspringen der Warnung aendert sich der Fenstertitel,
            # das Fenster wird deshalb neu gesucht - aber nur uebernommen, wenn
            # es auch gefunden wurde. Vorher stand hier der Selbstvergleich
            # $ps.Id -eq $ps.Id, der immer wahr war und $ps damit auch mit
            # $null ueberschrieben hat, wenn die Suche nichts fand.
            $ps2 = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -like $TabNameLogin
            if ($ps2 -and $ps2.Id) {
                $ps = $ps2
            }
        }

        #Login
        Write-Host $Name 'Check for Login' $Login;
        if ($Login) {
            Login -Name $Name -Ps $ps -Username $Username -Pw $Pw
            # Wie oben: nach dem Login traegt das Fenster den Zieltitel. Neu
            # suchen, aber nur bei Treffer uebernehmen.
            $ps2 = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -like $TabName
            if ($ps2 -and $ps2.Id) {
                $ps = $ps2
            }
        }

        # Erfolgreich per Titel-Match gefunden -> im State vermerken
        $OpenedTabsState[$Name] = @{ URL = $URL; OpenedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); EdgePid = $ps.Id }
        Save-OpenedTabsState -State $OpenedTabsState
    }
    else {
        Write-Log "Tab/Fenster fuer '$Name' konnte nach dem Oeffnen nicht per Titel-Match gefunden werden (Titel-Match auf '$TabName' fehlgeschlagen)." 'WARN'

        # WICHTIG: Trotz fehlgeschlagenem Titel-Match wurde der Tab oben
        # bereits geoeffnet (im bestehenden Fenster oder neuen Fenster).
        # Damit beim NAECHSTEN Lauf nicht erneut ein Tab aufgemacht wird,
        # wird der Vorgang trotzdem im State vermerkt (Stufe-1-Absicherung).
        # Falls $targetEdgePid gesetzt ist (bestehendes Fenster genutzt),
        # wird dieser verwendet, sonst der neueste laufende msedge-Prozess.
        $fallbackPid = $null
        if ($targetEdgePid) {
            $fallbackPid = $targetEdgePid
        }
        else {
            $newest = Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
            if ($newest) { $fallbackPid = $newest.Id }
        }

        if ($fallbackPid) {
            Write-Log "Vermerke Tab '$Name' im State (PID $fallbackPid) trotz fehlgeschlagenem Titel-Match, um doppeltes Oeffnen beim naechsten Lauf zu vermeiden." 'WARN'
            $OpenedTabsState[$Name] = @{ URL = $URL; OpenedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); EdgePid = $fallbackPid }
            Save-OpenedTabsState -State $OpenedTabsState

            if (-Not $ps -or $ps.Id -eq $null) {
                $ps = Get-Process -Id $fallbackPid -ErrorAction SilentlyContinue
            }
        }
    }
    return($ps)
}

function FindByName {
    Param(
        [Parameter(Mandatory = $true)]
        [String]$tabNameDashbord
    )
    $TypeDef2 = @"

using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Api
{

public class WinStruct
{
   public string WinTitle {get; set; }
   public int MainWindowHandle { get; set; }
}

public class ApiDef
{
   private delegate bool CallBackPtr(int hwnd, int lParam);
   private static CallBackPtr callBackPtr = Callback;
   private static List<WinStruct> _WinStructList = new List<WinStruct>();

   [DllImport("User32.dll")]
   [return: MarshalAs(UnmanagedType.Bool)]
   private static extern bool EnumWindows(CallBackPtr lpEnumFunc, IntPtr lParam);

   [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
   static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

   private static bool Callback(int hWnd, int lparam)
   {
       StringBuilder sb = new StringBuilder(256);
       int res = GetWindowText((IntPtr)hWnd, sb, 256);
      _WinStructList.Add(new WinStruct { MainWindowHandle = hWnd, WinTitle = sb.ToString() });
       return true;
   }  

   public static List<WinStruct> GetWindows()
   {
      _WinStructList = new List<WinStruct>();
      EnumWindows(callBackPtr, IntPtr.Zero);
      return _WinStructList;
   }

}
}
"@
    if (-Not ([System.Management.Automation.PSTypeName]'Api.ApiDef').Type) {
        Add-Type -TypeDefinition $TypeDef2
    }
    $ps = [Api.Apidef]::GetWindows() | Where-Object { $_.WinTitle.ToUpper() -like $tabNameDashbord.ToUpper() }
    return ($ps)
}

function Invoke-AppActivate {
    <#
        Aktiviert ein Fenster ueber WScript.Shell mit BEGRENZTER Anzahl
        Versuche und meldet Erfolg oder Misserfolg zurueck.

        Vorher warteten ThisIsUnsafe und Login jeweils in einer Schleife OHNE
        Abbruchbedingung darauf, dass AppActivate einmal $true liefert. Genau
        dieser Fall tritt aber nie ein, wenn das Zielfenster mit hoeheren
        Rechten laeuft als dieses Skript (UIPI/Focus-Stealing-Schutz) - das
        Skript blieb dann dauerhaft haengen, ohne jeden Logeintrag. Die
        Begrenzung entspricht dem Muster, das Open-UrlInExistingWindow und
        Set-WindowFullscreen im selben Skript schon verwenden.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$Wshell,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [Object]$Ps,
        [int]$MaxTries = 10
    )

    if (-Not $Ps -or -Not $Ps.Id) {
        Write-Log "Fensteraktivierung nicht moeglich: kein gueltiger Prozess uebergeben." 'WARN'
        return $false
    }

    for ($try = 0; $try -lt $MaxTries; $try++) {
        if ($Wshell.AppActivate($Ps.Id)) {
            return $true
        }
        Start-Sleep -MilliSeconds 300
    }

    Write-Log "Fenster (PID $($Ps.Id)) konnte in $MaxTries Versuchen nicht aktiviert werden. Moegliche Ursache: Das Zielprogramm laeuft mit hoeheren Rechten als dieses Skript." 'WARN'
    return $false
}

function ConvertTo-SendKeysLiteral {
    <#
        SendKeys deutet + ^ % ~ ( ) { } [ ] als Steuerzeichen. Ein Passwort
        oder Benutzername mit einem dieser Zeichen wuerde sonst verstuemmelt
        oder als Tastenkombination interpretiert (aus "a+b" wird z.B. ein
        Shift-Druck). Geschweifte Klammern um das Sonderzeichen machen es
        wieder zu einem Literal.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String]$Text
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        if ('+^%~(){}[]'.Contains($char)) {
            [void]$builder.Append('{').Append($char).Append('}')
        }
        else {
            [void]$builder.Append($char)
        }
    }
    return $builder.ToString()
}

function ThisIsUnsafe {
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$ps
    )

    $wshellThisIsUnsafe = New-Object -ComObject wscript.shell

    if (-Not (Invoke-AppActivate -Wshell $wshellThisIsUnsafe -Ps $ps)) {
        Write-Log "Zertifikatswarnung konnte nicht uebersprungen werden - das Fenster liess sich nicht aktivieren." 'WARN'
        return
    }

    Write-Log "Ueberspringe Zertifikatswarnung im Fenster '$($ps.MainWindowTitle)' (Eingabe 'thisisunsafe')."

    # Zeichenweise mit kurzer Pause: Die Interstitial-Seite wertet die
    # Tastenfolge einzeln aus, zu schnelles Tippen laesst Zeichen verloren
    # gehen. Der Block stand vorher in einem if ($ps.Id -eq $null) - eine
    # Bedingung, die an dieser Stelle nie zutreffen kann, weil die
    # Aktivierung darueber bereits eine gueltige PID braucht. Die Eingabe
    # wurde damit nie ausgefuehrt.
    Start-Sleep -Seconds 1
    foreach ($char in 'thisisunsafe'.ToCharArray()) {
        $wshellThisIsUnsafe.SendKeys($char)
        Start-Sleep -MilliSeconds 100
    }
}

function Login {
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$Name,
        [Parameter(Mandatory = $true)]
        [Object]$ps,
        [Parameter(Mandatory = $true)]
        [Object]$Username,
        [Parameter(Mandatory = $true)]
        [Object]$Pw
    )
    Write-Log "Login fuer '$Name' im Fenster '$($ps.MainWindowTitle)'."

    Start-Sleep -Seconds 1
    $wshellLogin = New-Object -ComObject wscript.shell

    # Abbruch statt Weitermachen: Ohne aktiviertes Zielfenster wuerden die
    # folgenden SendKeys die Zugangsdaten in irgendein anderes gerade aktives
    # Fenster tippen - im Zweifel in eine Suchleiste oder einen Chat.
    if (-Not (Invoke-AppActivate -Wshell $wshellLogin -Ps $ps)) {
        Write-Log "Login fuer '$Name' wird ABGEBROCHEN: Das Zielfenster liess sich nicht aktivieren. Es werden bewusst keine Zugangsdaten gesendet, damit sie nicht in einem fremden Fenster landen." 'WARN'
        return
    }

    #Special handling based on Name
    switch -wildcard ($Name) {
        "Baader*" {
            $wshellLogin.SendKeys('{TAB}')
        }
        Default {}
    }

    #Login
    Start-Sleep -Seconds 1
    $wshellLogin.SendKeys((ConvertTo-SendKeysLiteral -Text $Username))
    Start-Sleep -Seconds 1
    $wshellLogin.SendKeys('{TAB}')
    Start-Sleep -Seconds 1
    $wshellLogin.SendKeys((ConvertTo-SendKeysLiteral -Text $Pw))
    Start-Sleep -Seconds 1
    $wshellLogin.SendKeys('{ENTER}')
    Start-Sleep -Seconds 1
}

function CicleTabs {
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$pss,
        [Parameter(Mandatory = $true)]
        [int]$repeater,
        [Parameter(Mandatory = $true)]
        [int]$wait
    )
    <#
        Schaltet reihum durch die geoeffneten Tabs.

        $pss enthaelt je konfiguriertem Tab einen Prozessverweis. Weil alle
        Tabs bewusst in EINEM Edge-Fenster liegen (siehe
        Assert-SingleBrowserWindow), zeigen diese Eintraege aber auf dasselbe
        Fenster. Das bisherige SetForegroundWindow je Eintrag holte also
        immer wieder dasselbe, ohnehin aktive Fenster nach vorn und wechselte
        keinen einzigen Tab - der Rundlauf zeigte ein Standbild.

        Ein Tabwechsel braucht einen echten Tastendruck: Strg+Tab.
    #>
    if (-Not ([System.Management.Automation.PSTypeName]'Program').Type) {
        Add-Type "using System;using System.Runtime.InteropServices;public class Program {[DllImport(`"user32.dll`")][return: MarshalAs(UnmanagedType.Bool)]public static extern bool SetForegroundWindow(IntPtr hWnd);}"
    }

    $window = @($pss | Where-Object { $_ -ne $null -and $_.MainWindowHandle -ne 0 }) | Select-Object -First 1
    if (-Not $window) {
        Write-Log "Tab-Rundlauf: Kein Browserfenster mit gueltigem Fensterhandle vorhanden - Rundlauf wird uebersprungen." 'WARN'
        return
    }

    $tabCount = @($pss | Where-Object { $_ -ne $null }).Count
    if ($tabCount -le 1) {
        Write-Log "Tab-Rundlauf: Nur $tabCount Tab(s) referenziert - es gibt nichts durchzuschalten." 'WARN'
        return
    }

    Write-Log "Tab-Rundlauf gestartet: $tabCount Tabs im Fenster PID $($window.Id), $repeater Durchgaenge, $wait Sekunden je Tab."

    $wshellCycle = New-Object -ComObject wscript.shell

    for ($i = 0; $i -lt $repeater; $i++) {
        for ($t = 0; $t -lt $tabCount; $t++) {

            # Vor jedem Wechsel neu aktivieren: Uebernimmt zwischendurch ein
            # anderes Fenster den Fokus, ginge Strg+Tab sonst dorthin.
            [Program]::SetForegroundWindow($window.MainWindowHandle) | Out-Null
            if (-Not (Invoke-AppActivate -Wshell $wshellCycle -Ps $window)) {
                Write-Log "Tab-Rundlauf abgebrochen: Das Browserfenster liess sich nicht mehr aktivieren." 'WARN'
                return
            }

            $wshellCycle.SendKeys('^{TAB}')
            Start-Sleep -Seconds $wait
        }
    }

    Write-Log "Tab-Rundlauf beendet nach $repeater Durchgang/Durchgaengen."
}

# ============================================================
# TEIL 3: Vollbild-Rundlauf ueber alle referenzierten Fenster
# (Browser-Tabs UND ueberwachte Programme gemeinsam)
# ============================================================

# ------------------------------------------------------------
# SICHERHEITS-HARDSTOP (hartcodiert, NICHT ueber settings.json
# veraenderbar): Der komplette Vollbild-Rundlauf darf zur
# Absicherung aktuell nicht laenger als 2 Minuten laufen, egal
# wie "fullscreenCycleIntervalSeconds" oder die Anzahl Fenster
# konfiguriert ist. Sobald das Verhalten im produktiven Betrieb
# final geprueft ist, kann dieser Wert erhoeht/entfernt werden.
# ------------------------------------------------------------
$script:HardStopFullscreenCycleSeconds = 120

function Test-IsForegroundWindow {
    <#
        Echte Pruefung, ob ein Fenster (Handle) tatsaechlich das aktuelle
        Vordergrundfenster ist - unabhaengig davon, ob AppActivate/
        SetForegroundWindow $true zurueckgegeben haben (das sagt naemlich
        NICHTS Verlaessliches aus, siehe GetForegroundWindow-Vergleich).
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$ExpectedHandle
    )
    if (-Not ([System.Management.Automation.PSTypeName]'FgCheck').Type) {
        Add-Type "using System;using System.Runtime.InteropServices;public class FgCheck {[DllImport(`"user32.dll`")]public static extern IntPtr GetForegroundWindow();}"
    }
    $current = [FgCheck]::GetForegroundWindow()
    return ($current -eq $ExpectedHandle)
}

function Set-WindowFullscreen {
    <#
        Aktiviert ein Fenster (SetForegroundWindow + AppActivate) und schaltet
        es per F11 in den Vollbildmodus. F11 ist der Standard-Shortcut fuer
        "Vollbild" in Microsoft Edge sowie in vielen Windows-Anwendungen
        (u.a. Notepad++ ueber Ansicht > Vollbildmodus = ebenfalls F11).
        Fuer Programme ohne F11-Unterstuetzung ist das Verhalten harmlos
        (Tastenkombination wird ignoriert, Fenster bleibt aber im Vordergrund).

        WICHTIG - echte Erfolgspruefung: SetForegroundWindow/AppActivate
        koennen aus mehreren Gruenden lautlos fehlschlagen, ohne dass eine
        Exception geworfen wird - insbesondere durch Windows' "Focus
        Stealing Prevention" (UIPI) oder wenn die Ziel-App mit hoeheren
        Rechten (erhoeht/Administrator) laeuft als dieses Skript. Genau das
        ist typischerweise der Fall bei Videomanagement-Clients wie
        HD Witness/Nx Witness. Bisher wurde F11 in solchen Faellen trotzdem
        "blind" gesendet - dann landete der Tastendruck im FALSCHEN
        (tatsaechlich aktiven) Fenster, ohne dass ein Fehler sichtbar wurde.
        Jetzt wird nach der Aktivierung per GetForegroundWindow verifiziert,
        ob das Zielfenster wirklich im Vordergrund ist; falls nicht, wird
        das klar als WARN geloggt (kein stiller Fehlschlag mehr) und F11
        wird nur gesendet, wenn die Aktivierung nachweislich geklappt hat.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$Process,
        [Parameter(Mandatory = $true)]
        [String]$Label
    )

    if (-Not $Process -or $Process.MainWindowHandle -eq 0) {
        Write-Log "Vollbild-Rundlauf: Fenster fuer '$Label' nicht (mehr) verfuegbar - wird uebersprungen." 'WARN'
        return
    }

    try {
        $targetHandle = [IntPtr]$Process.MainWindowHandle

        [Program]::SetForegroundWindow($targetHandle) | Out-Null
        Start-Sleep -Milliseconds 200

        $wshellFs = New-Object -ComObject wscript.shell
        $activated = $false
        $tries = 0
        while (-not $activated -and $tries -lt 8) {
            $activated = $wshellFs.AppActivate($Process.Id)
            if (-not $activated) {
                # Erneuter Versuch ueber SetForegroundWindow, falls AppActivate
                # (arbeitet ueber Fenstertitel/PID) allein nicht reicht
                [Program]::SetForegroundWindow($targetHandle) | Out-Null
                Start-Sleep -Milliseconds 250
            }
            $tries++
        }

        Start-Sleep -Milliseconds 300

        # ECHTE Pruefung: ist das Zielfenster jetzt wirklich im Vordergrund?
        $isForeground = Test-IsForegroundWindow -ExpectedHandle $targetHandle

        if (-Not $isForeground) {
            Write-Log "Vollbild-Rundlauf: '$Label' (PID $($Process.Id)) konnte NICHT in den Vordergrund geholt werden (moegliche Ursache: fehlende Rechte/erhoehter Prozess, Windows Focus-Stealing-Schutz). F11 wird NICHT gesendet, um kein falsches Fenster zu beeinflussen." 'WARN'
            Write-Log "Hinweis: Falls '$Label' als Administrator laeuft, muss auch dieses Skript (bzw. der Task Scheduler-Task) als Administrator laufen, damit SetForegroundWindow/AppActivate funktionieren." 'WARN'
            return
        }

        $wshellFs.SendKeys('{F11}')

        Write-Log "Vollbild-Rundlauf: '$Label' (PID $($Process.Id)) aktiviert und in Vollbild geschaltet."
    }
    catch {
        Write-Log "Vollbild-Rundlauf: Fenster fuer '$Label' konnte nicht aktiviert werden: $($_.Exception.Message)" 'WARN'
    }
}

function Get-MonitoredAppWindowProcesses {
    <#
        Liefert zu ALLEN konfigurierten monitoredApps (Notepad++ UND
        HD Witness) die jeweils laufenden Prozesse MIT sichtbarem
        Hauptfenster (fuer den Vollbild-Rundlauf). Nutzt dieselbe
        Pfad-/Namenslogik wie Test-AppIsRunning, damit auch hier keine
        falschen Prozessnamen zu Fehltreffern fuehren.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Object[]]$MonitoredApps
    )

    $result = @()
    foreach ($app in $MonitoredApps) {
        if ([string]::IsNullOrWhiteSpace($app.Path)) { continue }
        $expectedProcessName = [System.IO.Path]::GetFileNameWithoutExtension($app.Path)
        $proc = Get-Process -Name $expectedProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($proc) {
            $result += [PSCustomObject]@{ Label = $app.Name; Process = $proc }
        }
        else {
            Write-Log "Vollbild-Rundlauf: Fuer '$($app.Name)' wurde kein Prozess mit sichtbarem Fenster gefunden - wird uebersprungen." 'WARN'
        }
    }
    return $result
}

function Invoke-FullscreenCycle {
    <#
        Wechselt reihum durch ALLE referenzierten Fenster:
          - alle aktiven Browser-Tabs/-Fenster aus dem Browser-Cycle ($BrowserWindows)
          - alle ueberwachten Programme aus monitoredApps ($MonitoredApps)
        und schaltet jedes davon nacheinander in den Vollbildmodus (F11),
        mit der konfigurierten Wartezeit "fullscreenCycleIntervalSeconds"
        zwischen den Wechseln.

        SICHERHEITS-HARDSTOP: Die Gesamtlaufzeit dieser Funktion ist hart auf
        $script:HardStopFullscreenCycleSeconds (aktuell 2 Minuten) begrenzt,
        unabhaengig von Intervall/Fensteranzahl. Nach Ablauf wird der Rundlauf
        sauber beendet und geloggt.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [Object[]]$BrowserWindows,
        [Parameter(Mandatory = $true)]
        [Object[]]$MonitoredApps,
        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds
    )

    if (-Not ([System.Management.Automation.PSTypeName]'Program').Type) {
        Add-Type "using System;using System.Runtime.InteropServices;public class Program {[DllImport(`"user32.dll`")][return: MarshalAs(UnmanagedType.Bool)]public static extern bool SetForegroundWindow(IntPtr hWnd);}"
    }

    # Zielliste aufbauen: Browserfenster + ueberwachte Programme, gemeinsam durchgewechselt
    $targets = @()

    foreach ($bp in $BrowserWindows) {
        if ($bp -ne $null -and $bp.MainWindowHandle -ne 0) {
            $targets += [PSCustomObject]@{ Label = "Browser: $($bp.MainWindowTitle)"; Process = $bp }
        }
    }

    $appTargets = Get-MonitoredAppWindowProcesses -MonitoredApps $MonitoredApps
    foreach ($at in $appTargets) {
        $targets += $at
    }

    if ($targets.Count -eq 0) {
        Write-Log "Vollbild-Rundlauf: Keine gueltigen Fenster (weder Browser noch Programme) gefunden - Rundlauf wird nicht gestartet." 'WARN'
        return
    }

    Write-Log "Vollbild-Rundlauf gestartet: $($targets.Count) Fenster referenziert, Intervall = $IntervalSeconds Sekunden, Hardstop = $script:HardStopFullscreenCycleSeconds Sekunden."

    $startTime = Get-Date
    $index = 0

    while ($true) {
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -ge $script:HardStopFullscreenCycleSeconds) {
            Write-Log "Vollbild-Rundlauf: Sicherheits-Hardstop von $script:HardStopFullscreenCycleSeconds Sekunden erreicht - Rundlauf wird beendet." 'WARN'
            break
        }

        $target = $targets[$index % $targets.Count]
        Set-WindowFullscreen -Process $target.Process -Label $target.Label

        # Restzeit bis zum Hardstop beruecksichtigen, damit die letzte Wartezeit
        # nicht ueber den Hardstop hinaus laeuft.
        $remaining = $script:HardStopFullscreenCycleSeconds - ((Get-Date) - $startTime).TotalSeconds
        $sleepSeconds = [Math]::Min($IntervalSeconds, [Math]::Max(0, $remaining))

        if ($sleepSeconds -le 0) {
            Write-Log "Vollbild-Rundlauf: Hardstop erreicht waehrend der Wartezeit - Rundlauf wird beendet." 'WARN'
            break
        }

        Start-Sleep -Seconds $sleepSeconds
        $index++
    }

    Write-Log "Vollbild-Rundlauf beendet nach $([Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)) Sekunden."
}

function Invoke-BrowserCycle {
    Param(
        [Parameter(Mandatory = $true)]
        [Object]$BrowserCycleSettings,
        [Parameter(Mandatory = $true)]
        [Object[]]$MonitoredApps
    )

    $wait = $BrowserCycleSettings.waitSeconds
    $Conf = $BrowserCycleSettings.tabs

    [bool]$CloseExtra = $true
    try { $CloseExtra = [System.Convert]::ToBoolean($BrowserCycleSettings.closeExtraBrowserWindows) } catch { $CloseExtra = $true }

    # Neue Variable aus settings.json: Intervall (Sekunden) fuer den Vollbild-Rundlauf.
    # Fallback auf 60s, falls nicht konfiguriert oder ungueltig.
    [int]$FullscreenCycleIntervalSeconds = 60
    try {
        if ($BrowserCycleSettings.fullscreenCycleIntervalSeconds) {
            $FullscreenCycleIntervalSeconds = [int]$BrowserCycleSettings.fullscreenCycleIntervalSeconds
        }
    } catch { $FullscreenCycleIntervalSeconds = 60 }
    if ($FullscreenCycleIntervalSeconds -le 0) { $FullscreenCycleIntervalSeconds = 60 }

    [Object]$pss = @()

    # Persistenten Tab-State laden (ueberlebt Skript-Neustarts, solange Edge laeuft)
    $OpenedTabsState = Get-OpenedTabsState

    $CountActive = ($Conf | Where-Object Active -eq $true | Measure-Object).Count

    if ($CountActive -gt 0) {
        foreach ($a in $Conf) {
            [bool]$Active = $false
            [bool]$ThisIsUnsafe = $false
            [bool]$Login = $false

            try { $Active = [System.Convert]::ToBoolean($a.Active) } catch { $Active = $false }
            try { $ThisIsUnsafe = [System.Convert]::ToBoolean($a.ThisIsUnsafe) } catch { $ThisIsUnsafe = $false }
            try { $Login = [System.Convert]::ToBoolean($a.Login) } catch { $Login = $false }

            if ($Active) {
                Write-Host $a.Name
                $pss += OpenUrlAndLogin -name $a.Name -url $a.URL -TabName $a.TabName -ThisIsUnsafe $ThisIsUnsafe -TabNameUnsafe $a.TabNameUnsafe -Login $Login -TabNameLogin $a.TabNameLogin -Username $a.Username -Pw $a.Pw -OpenedTabsState $OpenedTabsState
                Write-Host ''
            }
        }

        # Echte Pruefung + ggf. Bereinigung: am Ende darf nur EIN Browserfenster offen sein
        Assert-SingleBrowserWindow -CloseExtra $CloseExtra

        # ------------------------------------------------------------
        # NEU: Vollbild-Rundlauf ueber alle referenzierten Browserfenster
        # UND ueberwachten Programme, gesteuert ueber
        # "fullscreenCycleIntervalSeconds" aus settings.json.
        # Zur Absicherung aktuell hart auf max. 2 Minuten begrenzt
        # (siehe $script:HardStopFullscreenCycleSeconds).
        # ------------------------------------------------------------
        Invoke-FullscreenCycle -BrowserWindows $pss -MonitoredApps $MonitoredApps -IntervalSeconds $FullscreenCycleIntervalSeconds

        # Berechnung der Wiederholungen anhand der Sekunden pro 59 Min und
        # Wartezeit. Die 3540 setzen voraus, dass der Task Scheduler dieses
        # Skript stuendlich neu startet.
        $repeater = [int](3540 / $wait / $CountActive)
        if ($repeater -lt 1) {
            # Bei grossen waitSeconds ergibt die Ganzzahldivision 0 - der
            # Rundlauf haette dann stillschweigend gar nicht stattgefunden.
            Write-Log "Berechnete Durchgaenge waren $repeater (waitSeconds=$wait, aktive Tabs=$CountActive). Es wird mindestens ein Durchgang ausgefuehrt; fuer die volle Stunde muss waitSeconds kleiner sein." 'WARN'
            $repeater = 1
        }
        CicleTabs -pss $pss -repeater $repeater -wait $wait
    }
}


# ============================================================
# Hauptablauf
# ============================================================

Invoke-AppSupervisor -MonitoredApps $Settings.monitoredApps
Invoke-BrowserCycle -BrowserCycleSettings $Settings.browserCycle -MonitoredApps $Settings.monitoredApps
