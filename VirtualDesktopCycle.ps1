<#
    VirtualDesktopCycle.ps1

    PROTOTYP: Kiosk-/Wandanzeige-Rundlauf ueber WINDOWS VIRTUELLE DESKTOPS.

    GRUNDIDEE (Unterschied zu AppSupervisorAndBrowserCycle.ps1):
      Bisher wurde bei JEDEM Wechsel erneut SetForegroundWindow/AppActivate +
      F11 gegen den Focus-Stealing-Schutz (UIPI) gefahren. Das scheitert
      lautlos, sobald ein Zielprogramm mit hoeheren Rechten laeuft
      (z.B. HD Witness als Administrator).

      Hier bekommt stattdessen JEDES Ziel EINMALIG einen eigenen virtuellen
      Desktop und wird dort einmal in den Vollbildmodus gesetzt. Der Rundlauf
      besteht danach nur noch aus dem Desktop-Wechsel selbst. Der Vollbild-
      und Fokuszustand bleibt pro Desktop erhalten - es muss also nie wieder
      Fokus von einem fremden Fenster "gestohlen" werden.

    ZWEI BACKENDS, BEIM START GEPRUEFT:
      Windows hat keine offiziell zugesicherte API fuer virtuelle Desktops.
      Es gibt aber das Modul "VirtualDesktop" (MScholtes/PSVirtualDesktop),
      das die inoffizielle COM-Schnittstelle kapselt und deutlich mehr kann
      als Tastenkuerzel. Sein Nachteil: Microsoft hat die COM-GUIDs schon
      mehrfach mit Feature-Updates geaendert (dokumentierte Brueche u.a. bei
      Win11 21H2->22H2, Build 22581 und 23H2), danach braucht es eine zum
      Build passende Modulversion.

      Deshalb wird beim Start GEPRUEFT statt geraten: Das Skript versucht das
      Modul zu laden und einen echten Desktop-Wechsel auszufuehren. Klappt
      das, laeuft alles ueber das Modul; wirft es einen Fehler, faellt das
      Skript auf reine Tastenkuerzel zurueck. Ein Versionsbruch faellt damit
      beim Start auf und nicht mitten im Dauerbetrieb.

      Backend "Module" (bevorzugt):
        + Absolutes Umschalten auf Desktop N (kein Blaettern, kein Verzaehlen)
        + Echter Rundlauf inkl. Sprung vom letzten auf den ersten Desktop
        + Bereits laufende Fenster koennen VERSCHOBEN werden (Move-Window)
        Installation:  Install-Module VirtualDesktop -Scope AllUsers

      Backend "Hotkey" (Rueckfallebene):
        - Nur relatives Blaettern mit Win+Strg+Links/Rechts
        - Kein Wrap-Around: am letzten Desktop passiert bei "Rechts" NICHTS.
          Der Rundlauf laeuft deshalb als Pendel ("Bounce") oder mit
          schnellem Ruecklauf ("Rewind") - siehe cycleMode.
        - Die aktuelle Position ist nicht auslesbar; das Skript fuehrt Buch.
          Wer am Geraet manuell den Desktop wechselt, bringt die Zaehlung aus
          dem Tritt. Gegenmittel: Reset-ToFirstDesktop nutzt aus, dass es kein
          Wrap-Around gibt - genug Anschlaege nach links landen sicher auf
          Desktop 1.
        - Laufende Fenster sind NICHT verschiebbar (es gibt dafuer kein
          Tastenkuerzel). Ziele werden deshalb auf ihrem Desktop GESTARTET.

    WICHTIG - RECHTE:
      Synthetische Tastendruecke erreichen keine Fenster, die mit hoeheren
      Rechten laufen als das sendende Skript (UIPI, ein Sicherheitsfeature
      von Windows). Laeuft HD Witness erhoeht, muss auch dieses Skript
      erhoeht laufen - im Task Scheduler "Mit hoechsten Berechtigungen
      ausfuehren". Das betrifft BEIDE Backends, denn F11 fuer den
      Vollbildmodus ist in jedem Fall ein synthetischer Tastendruck.

    SINGLE-INSTANCE-PROGRAMME (z.B. Notepad++ in der Standardeinstellung)
      oeffnen beim zweiten Aufruf kein neues Fenster, sondern holen das
      bestehende nach vorn. Dafuer gibt es pro Ziel das Feld "Args"
      (Notepad++: "-multiInst"). Mit Backend "Module" ist das meist
      unnoetig, weil das bestehende Fenster einfach verschoben wird.

    Konfiguration: .\config\settings.json, Abschnitt "virtualDesktopCycle".

    STOPPEN: Mit maxRuntimeSeconds = 0 laeuft der Rundlauf endlos. Zum
    geordneten Beenden eine Datei "stop.txt" neben das Skript legen - sie wird
    beim naechsten Taktwechsel erkannt (also nach spaetestens
    intervalSeconds), verarbeitet und wieder geloescht.
#>

[CmdletBinding()]
Param(
    # Baut nur das Desktop-Layout auf und startet KEINEN Rundlauf.
    [Switch]$SetupOnly,

    # Startet den Rundlauf, ohne das Layout neu aufzubauen (Desktops/Fenster
    # stehen bereits aus einem frueheren Lauf).
    [Switch]$CycleOnly
)

$ConfigDir  = Join-Path $PSScriptRoot "config"
$ConfigPath = Join-Path $ConfigDir "settings.json"

$LogDir = Join-Path $PSScriptRoot "log"
if (-Not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("VirtualDesktopCycle_" + (Get-Date -Format "yyyyMMdd") + ".log")

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)][String]$Message,
        [ValidateSet('INFO','WARN','ERROR')][String]$Level = 'INFO'
    )
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# ============================================================
# Konfiguration
# ============================================================

function New-DefaultVirtualDesktopSettings {
    Param([Parameter(Mandatory = $true)][String]$Path)

    $defaults = [ordered]@{
        virtualDesktopCycle = [ordered]@{
            desktopBackend       = "Auto"
            intervalSeconds      = 60
            cycleMode            = "Bounce"
            fullscreen           = $true
            resetDesktopsOnStart = $false
            restartForPlacement  = $false
            maxRuntimeSeconds    = 300
            targets              = @(
                [ordered]@{
                    Active = $true
                    Type   = "App"
                    Name   = "Notepad++"
                    Path   = "C:\Program Files\Notepad++\notepad++.exe"
                    Args   = "-multiInst"
                }
                [ordered]@{
                    Active = $true
                    Type   = "App"
                    Name   = "HD Witness"
                    Path   = "C:\Program Files\Network Optix\Nx Witness\Client\6.1.2.42921\HD Witness.exe"
                    Args   = ""
                }
                [ordered]@{
                    Active = $true
                    Type   = "Url"
                    Name   = "Beispiel Dashboard"
                    URL    = "https://example.com/dashboard"
                    Args   = ""
                }
            )
        }
    }

    if (-Not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    $defaults | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

if (-Not (Test-Path $ConfigPath)) {
    New-DefaultVirtualDesktopSettings -Path $ConfigPath
    Write-Log "Keine settings.json gefunden - Standardkonfiguration wurde erstellt: $ConfigPath"
    # Hier wird bewusst abgebrochen: Mit der Vorlage wuerde das Skript
    # Desktops anlegen und https://example.com oeffnen.
    Write-Log "Bitte Pfade und URLs anpassen und danach erneut starten." 'WARN'
    return
}

try {
    $Settings = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Log "settings.json enthaelt ungueltiges JSON: $($_.Exception.Message)" 'ERROR'
    Write-Log "Haeufigste Ursache: Windows-Pfade mit einfachen Backslashes. In JSON muessen Backslashes verdoppelt werden (C:\\Program Files\\...)." 'ERROR'
    throw "Abbruch: settings.json ist ungueltig."
}

$VdConfig = $Settings.virtualDesktopCycle
if (-Not $VdConfig) {
    Write-Log "In settings.json fehlt der Abschnitt 'virtualDesktopCycle'. Bitte ergaenzen (Vorlage: Skript einmal ohne settings.json starten)." 'ERROR'
    throw "Abbruch: Abschnitt 'virtualDesktopCycle' fehlt."
}

[int]$IntervalSeconds = 60
if ([int]$VdConfig.intervalSeconds -gt 0) {
    $IntervalSeconds = [int]$VdConfig.intervalSeconds
}

[int]$MaxRuntimeSeconds = 300
if ($null -ne $VdConfig.maxRuntimeSeconds) {
    $MaxRuntimeSeconds = [int]$VdConfig.maxRuntimeSeconds
}

$CycleMode = "Bounce"
if ($VdConfig.cycleMode -in @('Bounce','Rewind')) { $CycleMode = $VdConfig.cycleMode }

# Auto = Modul probieren, sonst Hotkeys. Module/Hotkey erzwingen ein Backend
# (nuetzlich, um beide Wege auf der Zielmaschine zu vergleichen).
$BackendSetting = "Auto"
if ($VdConfig.desktopBackend -in @('Auto','Module','Hotkey')) { $BackendSetting = $VdConfig.desktopBackend }

function ConvertTo-BoolSetting {
    <#
        Ein blanker [bool]-Cast reicht hier nicht: In JSON landet schnell der
        STRING "false" statt des Wertes false, und [bool]"false" ist in
        PowerShell $true (jede nicht-leere Zeichenkette ist wahr). Das wuerde
        eine Einstellung stillschweigend ins Gegenteil verkehren.
    #>
    Param($Value, [bool]$Default)

    if ($null -eq $Value)  { return $Default }
    if ($Value -is [bool]) { return $Value }
    try { return [System.Convert]::ToBoolean($Value) } catch { return $Default }
}

[bool]$UseFullscreen        = ConvertTo-BoolSetting $VdConfig.fullscreen $true
[bool]$ResetDesktopsOnStart = ConvertTo-BoolSetting $VdConfig.resetDesktopsOnStart $false
[bool]$RestartForPlacement  = ConvertTo-BoolSetting $VdConfig.restartForPlacement $false

$Targets = @($VdConfig.targets | Where-Object { $_.Active -eq $true })

# ============================================================
# Win32-Basis: Tastatureingaben und Fensterabfragen
#
# WScript.Shell/SendKeys scheidet hier aus: SendKeys kennt KEINEN Modifier
# fuer die Windows-Taste (nur ^ = Strg, % = Alt, + = Shift). Die Hotkeys
# Win+Strg+Pfeil muessen deshalb ueber keybd_event erzeugt werden.
# ============================================================

if (-Not ([System.Management.Automation.PSTypeName]'VdInterop').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class VdInterop
{
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public const byte VK_LWIN    = 0x5B;
    public const byte VK_CONTROL = 0x11;
    public const byte VK_LEFT    = 0x25;
    public const byte VK_RIGHT   = 0x27;
    public const byte VK_D       = 0x44;
    public const byte VK_F4      = 0x73;
    public const byte VK_F11     = 0x7A;

    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP       = 0x0002;
}
"@
}

function Send-Key {
    Param(
        [Parameter(Mandatory = $true)][byte]$VirtualKey,
        [Switch]$KeyUp,
        [Switch]$Extended
    )
    $flags = 0
    if ($Extended) { $flags = $flags -bor [VdInterop]::KEYEVENTF_EXTENDEDKEY }
    if ($KeyUp)    { $flags = $flags -bor [VdInterop]::KEYEVENTF_KEYUP }
    [VdInterop]::keybd_event($VirtualKey, 0, $flags, [UIntPtr]::Zero)
}

function Reset-ModifierKeys {
    <#
        Regulaerer Loslass-Schritt jedes Hotkeys - Send-WinCtrlHotkey drueckt
        die Modifier nur und gibt sie hier wieder frei.

        Der Aufruf steht im finally-Zweig, damit die Modifier auch bei einem
        Abbruch mitten in der Tastenfolge losgelassen werden: Eine
        haengengebliebene Windows-Taste waere im unbeaufsichtigten Betrieb
        besonders unangenehm (Startmenue oeffnet sich, Tastatur reagiert
        scheinbar nicht mehr).
    #>
    Send-Key -VirtualKey ([VdInterop]::VK_CONTROL) -KeyUp
    Send-Key -VirtualKey ([VdInterop]::VK_LWIN) -KeyUp
}

function Send-WinCtrlHotkey {
    Param(
        [Parameter(Mandatory = $true)][byte]$VirtualKey,
        [Switch]$Extended
    )
    try {
        Send-Key -VirtualKey ([VdInterop]::VK_LWIN)
        Start-Sleep -Milliseconds 40
        Send-Key -VirtualKey ([VdInterop]::VK_CONTROL)
        Start-Sleep -Milliseconds 40

        if ($Extended) { Send-Key -VirtualKey $VirtualKey -Extended }
        else           { Send-Key -VirtualKey $VirtualKey }
        Start-Sleep -Milliseconds 40

        if ($Extended) { Send-Key -VirtualKey $VirtualKey -KeyUp -Extended }
        else           { Send-Key -VirtualKey $VirtualKey -KeyUp }
        Start-Sleep -Milliseconds 40
    }
    finally {
        Reset-ModifierKeys
    }
}

function Send-Fullscreen {
    Send-Key -VirtualKey ([VdInterop]::VK_F11)
    Start-Sleep -Milliseconds 60
    Send-Key -VirtualKey ([VdInterop]::VK_F11) -KeyUp
}

function Get-ForegroundProcessId {
    $hwnd = [VdInterop]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return 0 }
    [uint32]$processId = 0
    [void][VdInterop]::GetWindowThreadProcessId($hwnd, [ref]$processId)
    return [int]$processId
}

# ============================================================
# Backend "Hotkey": Desktops per Tastenkuerzel
# ============================================================

# Die Desktop-Umschaltung ist animiert. Zu kurze Wartezeiten fuehren dazu,
# dass der naechste Hotkey in die laufende Animation faellt und verschluckt
# wird. 700 ms sind auf traegerer Hardware erfahrungsgemaess noetig.
$script:DesktopSwitchDelayMs = 700

function Switch-DesktopRight {
    Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_RIGHT) -Extended
    Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
}

function Switch-DesktopLeft {
    Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_LEFT) -Extended
    Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
}

function Reset-ToFirstDesktop {
    <#
        Faehrt die Position deterministisch auf Desktop 1.

        Funktioniert genau deshalb, weil es KEIN Wrap-Around gibt: Weitere
        Win+Strg+Links-Anschlaege am linken Rand sind wirkungslos. Ein paar
        Anschlaege mehr als noetig sind also unschaedlich und machen die
        Position unabhaengig davon, wo der Rundlauf gerade stand.
    #>
    Param([int]$Steps = 12)

    Write-Log "Setze Desktop-Position zurueck auf Desktop 1 ($Steps x Win+Strg+Links)."
    for ($i = 0; $i -lt $Steps; $i++) {
        Switch-DesktopLeft
    }
}

function Reset-DesktopLayoutByHotkey {
    <#
        Reduziert die Anzahl virtueller Desktops auf genau einen.

        Ablauf: ganz nach rechts fahren, dann wiederholt Win+Strg+F4. Windows
        weigert sich, den LETZTEN verbliebenen Desktop zu schliessen - die
        Schleife laeuft also von selbst gegen den Anschlag.
    #>
    Param([int]$Steps = 12)

    for ($i = 0; $i -lt $Steps; $i++) {
        Switch-DesktopRight
    }
    for ($i = 0; $i -lt $Steps; $i++) {
        Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_F4)
        Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
    }
}

# ============================================================
# Backend-Auswahl und gemeinsame Schnittstelle
#
# Alles darunter spricht nur noch die Wrapper an, nie direkt das Modul oder
# die Hotkeys. $script:Backend ist danach 'Module' oder 'Hotkey'.
# ============================================================

$script:Backend = 'Hotkey'
# Nur im Hotkey-Backend gefuehrt - dort ist die Position nicht auslesbar.
$script:TrackedPosition = 1

function Initialize-DesktopBackend {
    <#
        Prueft das Modul mit genau den Aufrufen, die spaeter auch im Betrieb
        verwendet werden - Get-DesktopCount und ein echter Switch-Desktop.
        Ein reiner Import-Test wuerde zu wenig aussagen: Die bekannten
        Versionsbrueche zeigen sich erst beim COM-Zugriff, nicht beim Laden.

        Der Probe-Wechsel auf Desktop 0 ist kein Nebeneffekt, sondern genau
        der Ausgangszustand, den der Layout-Aufbau ohnehin braucht.
    #>
    Param([Parameter(Mandatory = $true)][String]$Preference)

    if ($Preference -eq 'Hotkey') {
        Write-Log "Backend 'Hotkey' ist in settings.json fest vorgegeben - das Modul wird nicht geprueft."
        $script:Backend = 'Hotkey'
        return
    }

    try {
        Import-Module VirtualDesktop -ErrorAction Stop

        $count = Get-DesktopCount -ErrorAction Stop
        if ($count -lt 1) { throw "Get-DesktopCount lieferte $count." }

        Switch-Desktop -Desktop 0 -ErrorAction Stop
        Start-Sleep -Milliseconds 300

        $script:Backend = 'Module'
        Write-Log "Backend 'Module': PowerShell-Modul VirtualDesktop geladen und geprueft ($count Desktop(s) vorhanden)."
        return
    }
    catch {
        $reason = $_.Exception.Message

        if ($Preference -eq 'Module') {
            Write-Log "Backend 'Module' war fest vorgegeben, ist aber nicht nutzbar: $reason" 'ERROR'
            throw "Abbruch: Backend 'Module' erzwungen, aber nicht verfuegbar."
        }

        Write-Log "Modul VirtualDesktop nicht nutzbar - es wird auf Tastenkuerzel zurueckgefallen. Grund: $reason" 'WARN'
        Write-Log "Falls das Modul fehlt: 'Install-Module VirtualDesktop -Scope AllUsers'. Falls es nach einem Windows-Feature-Update bricht: passende Modulversion fuer diesen Build installieren." 'WARN'
        $script:Backend = 'Hotkey'
    }
}

function Get-ActualDesktopCount {
    <# Echte Anzahl - im Hotkey-Backend nicht ermittelbar, daher $null. #>
    if ($script:Backend -eq 'Module') {
        try { return [int](Get-DesktopCount -ErrorAction Stop) } catch { return $null }
    }
    return $null
}

function Switch-ToDesktop {
    <# Wechselt auf den 1-basierten Desktop $Index. #>
    Param([Parameter(Mandatory = $true)][int]$Index)

    if ($script:Backend -eq 'Module') {
        Switch-Desktop -Desktop ($Index - 1)
        Start-Sleep -Milliseconds 300
        return
    }

    # Hotkey: nur relativ moeglich - Differenz zur gefuehrten Position laufen.
    $delta = $Index - $script:TrackedPosition
    if ($delta -gt 0) { for ($i = 0; $i -lt $delta; $i++)      { Switch-DesktopRight } }
    elseif ($delta -lt 0) { for ($i = 0; $i -lt -$delta; $i++) { Switch-DesktopLeft } }
    $script:TrackedPosition = $Index
}

function Add-DesktopAndSwitch {
    <# Legt einen Desktop am Ende an und wechselt dorthin. #>
    if ($script:Backend -eq 'Module') {
        New-Desktop | Switch-Desktop
        Start-Sleep -Milliseconds 300
        return
    }

    Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_D)
    Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
    $script:TrackedPosition++
}

function Reset-DesktopPosition {
    <# Stellt sicher, dass Desktop 1 aktiv ist. #>
    Param([int]$HotkeySteps = 12)

    if ($script:Backend -eq 'Module') {
        Switch-Desktop -Desktop 0
        Start-Sleep -Milliseconds 300
        return
    }

    Reset-ToFirstDesktop -Steps $HotkeySteps
    $script:TrackedPosition = 1
}

function Clear-ExtraDesktops {
    <#
        Baut alle Desktops bis auf einen ab.

        ACHTUNG: Beim Schliessen eines Desktops wandern dessen Fenster auf den
        Nachbardesktop; am Ende liegen alle Fenster auf Desktop 1. Programme
        werden dabei NICHT beendet, aber die Desktop-Aufteilung geht verloren.
        Deshalb standardmaessig deaktiviert (resetDesktopsOnStart).
    #>
    Param([int]$HotkeySteps = 12)

    Write-Log "Baue bestehende virtuelle Desktops ab (resetDesktopsOnStart aktiv)." 'WARN'

    if ($script:Backend -eq 'Module') {
        Remove-AllDesktops
        Start-Sleep -Milliseconds 300
    }
    else {
        Reset-DesktopLayoutByHotkey -Steps $HotkeySteps
        $script:TrackedPosition = 1
    }

    Write-Log "Desktop-Abbau abgeschlossen - es sollte nur noch Desktop 1 existieren."
}

function Move-WindowToCurrentDesktop {
    <#
        Holt ein bereits laufendes Fenster auf den aktuell aktiven Desktop.
        Das kann nur das Modul - fuer Tastenkuerzel gibt es dafuer schlicht
        kein Aequivalent in Windows.

        Rueckgabe: $true, wenn das Fenster verschoben wurde.
    #>
    Param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    if ($script:Backend -ne 'Module') { return $false }

    try {
        $Handle | Move-Window (Get-CurrentDesktop) | Out-Null
        Start-Sleep -Milliseconds 300
        return $true
    }
    catch {
        Write-Log "Fenster konnte nicht auf den aktuellen Desktop verschoben werden: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ============================================================
# Ziele auf Desktops verteilen
# ============================================================

function Get-TargetProcessName {
    Param([Parameter(Mandatory = $true)][Object]$Target)

    if ($Target.Type -eq 'Url') { return 'msedge' }
    if ([string]::IsNullOrWhiteSpace($Target.Path)) { return $null }
    return [System.IO.Path]::GetFileNameWithoutExtension($Target.Path)
}

function Get-RunningTargetWindow {
    <# Laufender Prozess des Ziels MIT sichtbarem Fenster, sonst $null. #>
    Param([Parameter(Mandatory = $true)][Object]$Target)

    $processName = Get-TargetProcessName -Target $Target
    if (-Not $processName) { return $null }

    # Neuestes Fenster zuerst: Nach dem Start eines Url-Ziels ist genau das
    # das gerade geoeffnete Edge-Fenster.
    return Get-Process -Name $processName -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowHandle -ne 0 } |
           Sort-Object StartTime -Descending |
           Select-Object -First 1
}

function Start-TargetOnCurrentDesktop {
    <#
        Startet ein Ziel auf dem GERADE aktiven Desktop und wartet, bis das
        zugehoerige Fenster existiert.

        Rueckgabe: der gestartete Prozess oder $null.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Target,
        [int]$WindowTimeoutSeconds = 30
    )

    $arguments = @()
    if (-Not [string]::IsNullOrWhiteSpace($Target.Args)) { $arguments += $Target.Args }

    if ($Target.Type -eq 'Url') {
        if ([string]::IsNullOrWhiteSpace($Target.URL)) {
            Write-Log "Ziel '$($Target.Name)': Typ 'Url', aber es ist keine URL konfiguriert - wird uebersprungen." 'WARN'
            return $null
        }
        $arguments += "--new-window"
        $arguments += $Target.URL
        $filePath = "msedge.exe"
    }
    else {
        if (-Not (Test-Path -LiteralPath $Target.Path -PathType Leaf)) {
            Write-Log "Ziel '$($Target.Name)': Pfad zeigt nicht auf eine ausfuehrbare Datei ($($Target.Path)) - wird uebersprungen." 'WARN'
            return $null
        }
        $filePath = $Target.Path
    }

    try {
        if ($arguments.Count -gt 0) {
            $proc = Start-Process -FilePath $filePath -ArgumentList $arguments -PassThru -ErrorAction Stop
        }
        else {
            $proc = Start-Process -FilePath $filePath -PassThru -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Ziel '$($Target.Name)' konnte nicht gestartet werden: $($_.Exception.Message)" 'WARN'
        return $null
    }

    # Auf das Hauptfenster warten. Refresh() ist zwingend - MainWindowHandle
    # wird im Prozessobjekt zwischengespeichert und bleibt sonst dauerhaft 0.
    $deadline = (Get-Date).AddSeconds($WindowTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $proc.Refresh()
            if (-Not $proc.HasExited -and $proc.MainWindowHandle -ne 0) {
                Write-Log "Ziel '$($Target.Name)' gestartet (PID $($proc.Id)), Fenster ist da."
                return $proc
            }
        }
        catch {
            break
        }
    }

    # Edge startet gern einen Wrapper-Prozess, der sich sofort beendet und das
    # Fenster einem bestehenden Browser-Prozess uebergibt. Dann liefert der
    # zurueckgegebene Prozess nie ein Fenster - das Fenster existiert aber.
    $fallback = Get-RunningTargetWindow -Target $Target
    if ($fallback) {
        Write-Log "Ziel '$($Target.Name)': Fenster ueber den Prozessnamen gefunden (PID $($fallback.Id))."
        return $fallback
    }

    Write-Log "Ziel '$($Target.Name)': Innerhalb von $WindowTimeoutSeconds Sekunden ist kein Fenster erschienen." 'WARN'
    return $null
}

function Set-TargetFullscreen {
    Param(
        [Parameter(Mandatory = $true)][Object]$Process,
        [Parameter(Mandatory = $true)][String]$Label,
        [Parameter(Mandatory = $true)][int]$DesktopIndex
    )

    # Das Fenster ist auf diesem Desktop allein und damit bereits im
    # Vordergrund - es muss also kein Fokus erkaempft werden. Zur Sicherheit
    # wird das trotzdem geprueft, bevor F11 rausgeht: sonst landet der
    # Tastendruck im falschen Fenster.
    Start-Sleep -Seconds 2
    $foregroundPid = Get-ForegroundProcessId

    if ($foregroundPid -eq $Process.Id) {
        Send-Fullscreen
        Write-Log "Ziel '$Label' auf Desktop $DesktopIndex in den Vollbildmodus geschaltet."
        return
    }

    Write-Log "Ziel '$Label': Vordergrundfenster gehoert zu PID $foregroundPid, erwartet war PID $($Process.Id). F11 wird NICHT gesendet, um kein fremdes Fenster umzuschalten." 'WARN'
    Write-Log "Haeufigste Ursache: '$Label' laeuft mit hoeheren Rechten als dieses Skript. Dann muss auch das Skript erhoeht laufen (Task Scheduler: 'Mit hoechsten Berechtigungen ausfuehren')." 'WARN'
}

function Initialize-DesktopLayout {
    <#
        Legt pro aktivem Ziel einen virtuellen Desktop an und sorgt dafuer,
        dass das Ziel dort liegt. Ziel 1 nutzt den bestehenden Desktop 1.

        Rueckgabe: Anzahl belegter Desktops.
    #>
    Param([Parameter(Mandatory = $true)][Object[]]$Targets)

    # Ein paar Anschlaege mehr als Ziele, damit der Anschlag sicher erreicht
    # wird, auch wenn noch Desktops aus einem frueheren Lauf offen sind.
    $resetSteps = [Math]::Max(12, $Targets.Count + 5)

    if ($ResetDesktopsOnStart) {
        # Danach existiert nur noch Desktop 1, man steht also bereits dort.
        Clear-ExtraDesktops -HotkeySteps $resetSteps
    }
    else {
        if ($script:Backend -eq 'Hotkey') {
            # Win+Strg+D haengt den neuen Desktop immer ganz RECHTS an.
            # Existieren beim Start noch Desktops aus einem frueheren Lauf,
            # liegen die Ziele danach nicht mehr lueckenlos auf Desktop 1..N
            # und die Zaehlung im Rundlauf passt nicht mehr zur Realitaet.
            Write-Log "Hinweis: Der Layout-Aufbau geht davon aus, dass beim Start genau EIN virtueller Desktop existiert (Normalzustand nach dem Anmelden). Sind noch Desktops offen, 'resetDesktopsOnStart' aktivieren." 'WARN'
        }
        Reset-DesktopPosition -HotkeySteps $resetSteps
    }

    $desktopIndex = 0
    foreach ($target in $Targets) {

        if ($desktopIndex -gt 0) {
            Add-DesktopAndSwitch
        }
        $desktopIndex++

        Write-Log "Desktop $desktopIndex : richte Ziel '$($target.Name)' ein."

        # Url-Ziele sind ausgenommen: Edge laeuft praktisch immer schon, und
        # ein weiteres Fenster per --new-window ist genau das, was hier
        # gebraucht wird.
        $existing = $null
        if ($target.Type -ne 'Url') {
            $existing = Get-RunningTargetWindow -Target $target
        }

        $proc = $null

        if ($existing) {
            if (Move-WindowToCurrentDesktop -Handle $existing.MainWindowHandle) {
                Write-Log "Ziel '$($target.Name)' lief bereits (PID $($existing.Id)) und wurde auf Desktop $desktopIndex verschoben - kein Neustart noetig."
                $proc = $existing
            }
            elseif ($RestartForPlacement) {
                Write-Log "Ziel '$($target.Name)' laeuft bereits und laesst sich nicht verschieben - wird gemaess 'restartForPlacement' beendet und auf Desktop $desktopIndex neu gestartet." 'WARN'
                Get-Process -Id $existing.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            else {
                Write-Log "Ziel '$($target.Name)' laeuft bereits und laesst sich mit Backend '$($script:Backend)' nicht verschieben - das bestehende Fenster bleibt auf seinem Desktop, es wird zusaetzlich eine neue Instanz auf Desktop $desktopIndex gestartet." 'WARN'
                Write-Log "Ohne 'Args' fuer Mehrfachinstanzen holt der Start nur das alte Fenster nach vorn. Abhilfe: Modul VirtualDesktop installieren, 'restartForPlacement' aktivieren, oder 'Args' setzen (Notepad++: -multiInst)." 'WARN'
            }
        }

        if (-Not $proc) {
            $proc = Start-TargetOnCurrentDesktop -Target $target
        }
        if (-Not $proc) { continue }

        if ($UseFullscreen) {
            Set-TargetFullscreen -Process $proc -Label $target.Name -DesktopIndex $desktopIndex
        }
    }

    Write-Log "Desktop-Layout aufgebaut: $desktopIndex Desktop(s) belegt (Backend '$($script:Backend)')."
    return $desktopIndex
}

# ============================================================
# Rundlauf
# ============================================================

function Invoke-DesktopCycle {
    <#
        Schaltet im Takt von $IntervalSeconds durch die Desktops.

        Backend 'Module': echter Rundlauf 1..N..1 per absolutem Wechsel.

        Backend 'Hotkey': Windows springt am letzten Desktop NICHT auf den
        ersten zurueck, deshalb zwei Ersatzmuster:
          Bounce - vor und zurueck (ruhiges Bild; die mittleren Desktops sind
                   pro Durchgang zweimal zu sehen)
          Rewind - vorwaerts bis zum Ende, dann schnell zurueck auf Desktop 1
                   (gleiche Standzeit fuer alle, dafuer kurzes Durchblitzen)
    #>
    Param(
        [Parameter(Mandatory = $true)][int]$DesktopCount,
        [Parameter(Mandatory = $true)][int]$IntervalSeconds,
        [Parameter(Mandatory = $true)][int]$MaxRuntimeSeconds,
        [Parameter(Mandatory = $true)][String]$Mode
    )

    if ($DesktopCount -le 1) {
        Write-Log "Rundlauf nicht moeglich: nur $DesktopCount Desktop(s) belegt." 'WARN'
        return
    }

    $startTime = Get-Date
    $position  = 1

    # Notbremse fuer den unbeaufsichtigten Betrieb: Mit maxRuntimeSeconds = 0
    # laeuft der Rundlauf endlos. Ohne diese Datei bliebe nur, den Prozess
    # abzuschiessen - auf einer Wandanzeige ohne Tastatur keine Option.
    $StopFile = Join-Path $PSScriptRoot "stop.txt"
    if (Test-Path -LiteralPath $StopFile) {
        Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    }

    $modeLabel = if ($script:Backend -eq 'Module') { "Rundlauf" } else { $Mode }
    $limitLabel = if ($MaxRuntimeSeconds -gt 0) { "Laufzeitgrenze $MaxRuntimeSeconds s" } else { "ohne Laufzeitgrenze" }
    Write-Log "Rundlauf gestartet: $DesktopCount Desktops, Intervall $IntervalSeconds s, Backend '$($script:Backend)', Modus $modeLabel, $limitLabel."

    while ($true) {

        if (Test-Path -LiteralPath $StopFile) {
            Write-Log "Stopp-Datei '$StopFile' gefunden - Rundlauf wird beendet."
            Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
            break
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($MaxRuntimeSeconds -gt 0 -and $elapsed -ge $MaxRuntimeSeconds) {
            Write-Log "Laufzeitgrenze von $MaxRuntimeSeconds Sekunden erreicht - Rundlauf wird beendet."
            break
        }

        $sleepSeconds = $IntervalSeconds
        if ($MaxRuntimeSeconds -gt 0) {
            $remaining = $MaxRuntimeSeconds - $elapsed
            $sleepSeconds = [Math]::Min($IntervalSeconds, [Math]::Max(0, $remaining))
        }
        if ($sleepSeconds -le 0) { break }

        Start-Sleep -Seconds $sleepSeconds

        if ($script:Backend -eq 'Module') {
            $position = ($position % $DesktopCount) + 1
            Switch-ToDesktop -Index $position
        }
        elseif ($Mode -eq 'Bounce') {
            if ($position -ge $DesktopCount) { $direction = -1 }
            elseif ($position -le 1)         { $direction = 1 }

            if ($direction -eq 1) { $position++ } else { $position-- }
            Switch-ToDesktop -Index $position
        }
        else {
            if ($position -ge $DesktopCount) {
                # Zurueck auf Desktop 1. Switch-ToDesktop laeuft die Differenz
                # ohne Standzeit ab, damit die uebersprungenen Desktops nicht
                # als vollwertige Station erscheinen.
                $position = 1
            }
            else {
                $position++
            }
            Switch-ToDesktop -Index $position
        }

        Write-Log "Aktiver Desktop: $position von $DesktopCount."
    }

    Write-Log "Rundlauf beendet nach $([Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)) Sekunden."
}

# ============================================================
# Hauptablauf
# ============================================================

if ($Targets.Count -eq 0) {
    Write-Log "Keine aktiven Ziele in settings.json (virtualDesktopCycle.targets) - nichts zu tun." 'WARN'
    return
}

Write-Log "VirtualDesktopCycle startet mit $($Targets.Count) aktiven Ziel(en)."

Initialize-DesktopBackend -Preference $BackendSetting

if ($CycleOnly) {
    Reset-DesktopPosition -HotkeySteps ([Math]::Max(12, $Targets.Count + 5))

    # Mit Modul ist die echte Anzahl bekannt; per Hotkey bleibt nur die
    # Annahme "ein Desktop je Ziel" aus dem vorherigen Lauf.
    $desktopCount = Get-ActualDesktopCount
    if (-Not $desktopCount) { $desktopCount = $Targets.Count }

    Write-Log "CycleOnly: Layout wird nicht neu aufgebaut, es wird mit $desktopCount Desktop(s) gearbeitet."
}
else {
    $desktopCount = Initialize-DesktopLayout -Targets $Targets
}

if ($SetupOnly) {
    Write-Log "SetupOnly: Layout steht, es wird kein Rundlauf gestartet."
    return
}

Invoke-DesktopCycle -DesktopCount $desktopCount `
                    -IntervalSeconds $IntervalSeconds `
                    -MaxRuntimeSeconds $MaxRuntimeSeconds `
                    -Mode $CycleMode
