<#
    VirtualDesktopCycle.ps1

    PROTOTYP: Kiosk-/Wandanzeige-Rundlauf ueber WINDOWS VIRTUELLE DESKTOPS,
    gesteuert ausschliesslich per HOTKEYS (kein VirtualDesktopAccessor.dll,
    keine undokumentierte COM-API).

    GRUNDIDEE (Unterschied zu AppSupervisorAndBrowserCycle.ps1):
      Bisher wurde bei JEDEM Wechsel erneut SetForegroundWindow/AppActivate +
      F11 gegen den Focus-Stealing-Schutz (UIPI) gefahren. Das scheitert
      lautlos, sobald ein Zielprogramm mit hoeheren Rechten laeuft
      (z.B. HD Witness als Administrator).

      Hier bekommt stattdessen JEDES Ziel EINMALIG einen eigenen virtuellen
      Desktop und wird dort einmal in den Vollbildmodus gesetzt. Der Rundlauf
      besteht danach nur noch aus einem einzigen System-Hotkey
      (Win+Strg+Pfeil). Der Vollbild- und Fokuszustand bleibt pro Desktop
      erhalten - es muss also nie wieder Fokus von einem fremden Fenster
      "gestohlen" werden.

    WIE FENSTER AUF EINEN DESKTOP KOMMEN:
      Windows bietet KEINEN Hotkey fuer "Fenster auf Desktop N verschieben"
      (das geht nur per Maus in der Task-Ansicht oder ueber die inoffizielle
      COM-API). Der Trick hier: Ein neu gestartetes Programm oeffnet sein
      Fenster immer auf dem GERADE AKTIVEN Desktop. Das Skript wechselt also
      erst auf den Zieldesktop und STARTET das Programm dann dort.

    BEKANNTE GRENZEN (bitte vor dem Produktiveinsatz testen):
      1) KEIN WRAP-AROUND: Win+Strg+Rechts am letzten Desktop macht NICHTS
         (Windows springt nicht zurueck auf Desktop 1). Der Rundlauf ist
         deshalb als Pendel ("Bounce") bzw. als schneller Ruecklauf
         ("Rewind") implementiert - siehe cycleMode.
      2) OPEN LOOP: Der aktuell aktive Desktop laesst sich ohne COM-API nicht
         auslesen. Das Skript fuehrt daher Buch ueber seine Position. Wenn
         jemand am Geraet manuell den Desktop wechselt, laeuft die Zaehlung
         aus dem Tritt. Gegenmittel ist Reset-ToFirstDesktop: Weil es kein
         Wrap-Around gibt, landet man durch ausreichend viele
         Win+Strg+Links-Anschlaege garantiert auf Desktop 1.
      3) BEREITS LAUFENDE PROGRAMME lassen sich per Hotkey NICHT auf einen
         anderen Desktop verschieben. Ein Programm, das schon laeuft, bleibt
         auf seinem Desktop. Das Skript erkennt das und protokolliert es;
         mit "restartForPlacement" kann es das Programm gezielt neu starten.
      4) SINGLE-INSTANCE-PROGRAMME (z.B. Notepad++ in der Standard-
         einstellung) oeffnen beim zweiten Aufruf KEIN neues Fenster, sondern
         holen das bestehende Fenster auf dessen altem Desktop nach vorn.
         Dafuer gibt es pro Ziel das Feld "Args" (Notepad++: "-multiInst").
      5) AUSGANGSZUSTAND: Win+Strg+D haengt einen neuen Desktop immer ganz
         rechts an. Der Layout-Aufbau setzt deshalb voraus, dass beim Start
         genau EIN virtueller Desktop existiert (Normalzustand nach dem
         Anmelden). Andernfalls "resetDesktopsOnStart" aktivieren.
      6) ERHOEHTE PROZESSE: Ob ein nicht-erhoehtes Skript den System-Hotkey
         ausloesen kann, waehrend ein erhoehtes Fenster im Vordergrund ist,
         muss auf der Zielmaschine geprueft werden. Im Zweifel dieses Skript
         ebenfalls als Administrator starten (Task Scheduler: "Mit hoechsten
         Berechtigungen ausfuehren").

    Konfiguration: .\config\settings.json, Abschnitt "virtualDesktopCycle".
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
            intervalSeconds     = 60
            cycleMode           = "Bounce"
            fullscreen          = $true
            resetDesktopsOnStart = $false
            restartForPlacement = $false
            maxRuntimeSeconds   = 300
            targets             = @(
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
    Write-Log "Bitte Pfade und URLs anpassen, danach erneut starten." 'WARN'
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
if ($VdConfig.intervalSeconds -and [int]$VdConfig.intervalSeconds -gt 0) {
    $IntervalSeconds = [int]$VdConfig.intervalSeconds
}

[int]$MaxRuntimeSeconds = 300
if ($null -ne $VdConfig.maxRuntimeSeconds) {
    $MaxRuntimeSeconds = [int]$VdConfig.maxRuntimeSeconds
}

$CycleMode = "Bounce"
if ($VdConfig.cycleMode -in @('Bounce','Rewind')) { $CycleMode = $VdConfig.cycleMode }

[bool]$UseFullscreen = $true
try { if ($null -ne $VdConfig.fullscreen) { $UseFullscreen = [System.Convert]::ToBoolean($VdConfig.fullscreen) } } catch { }

[bool]$ResetDesktopsOnStart = $false
try { if ($null -ne $VdConfig.resetDesktopsOnStart) { $ResetDesktopsOnStart = [System.Convert]::ToBoolean($VdConfig.resetDesktopsOnStart) } } catch { }

[bool]$RestartForPlacement = $false
try { if ($null -ne $VdConfig.restartForPlacement) { $RestartForPlacement = [System.Convert]::ToBoolean($VdConfig.restartForPlacement) } } catch { }

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
        Gibt Win und Strg zwangsweise frei. Ein haengengebliebener
        Modifier waere im unbeaufsichtigten Dauerbetrieb besonders
        unangenehm (Startmenue oeffnet sich, Tastatur reagiert scheinbar
        nicht mehr), deshalb laeuft das nach jedem Hotkey im finally-Zweig.
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
# Virtuelle Desktops (nur Hotkeys)
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

function New-VirtualDesktop {
    <# Win+Strg+D legt einen Desktop am ENDE an und wechselt direkt dorthin. #>
    Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_D)
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
        Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_LEFT) -Extended
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
}

function Reset-DesktopLayout {
    <#
        Reduziert die Anzahl virtueller Desktops auf genau einen.

        Ablauf: ganz nach rechts fahren, dann wiederholt Win+Strg+F4. Windows
        weigert sich, den LETZTEN verbliebenen Desktop zu schliessen - die
        Schleife laeuft also von selbst gegen den Anschlag.

        ACHTUNG: Beim Schliessen eines Desktops wandern dessen Fenster auf den
        Nachbardesktop; am Ende liegen alle Fenster auf Desktop 1. Programme
        werden dabei NICHT beendet, aber die Desktop-Aufteilung geht verloren.
        Deshalb standardmaessig deaktiviert (resetDesktopsOnStart).
    #>
    Param([int]$Steps = 12)

    Write-Log "Baue bestehende virtuelle Desktops ab (resetDesktopsOnStart aktiv)." 'WARN'
    for ($i = 0; $i -lt $Steps; $i++) {
        Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_RIGHT) -Extended
        Start-Sleep -Milliseconds 250
    }
    for ($i = 0; $i -lt $Steps; $i++) {
        Send-WinCtrlHotkey -VirtualKey ([VdInterop]::VK_F4)
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds $script:DesktopSwitchDelayMs
    Write-Log "Desktop-Abbau abgeschlossen - es sollte nur noch Desktop 1 existieren."
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
    $processName = Get-TargetProcessName -Target $Target
    if ($processName) {
        $fallback = Get-Process -Name $processName -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowHandle -ne 0 } |
                    Sort-Object StartTime -Descending |
                    Select-Object -First 1
        if ($fallback) {
            Write-Log "Ziel '$($Target.Name)': Fenster ueber Prozessnamen '$processName' gefunden (PID $($fallback.Id))."
            return $fallback
        }
    }

    Write-Log "Ziel '$($Target.Name)': Innerhalb von $WindowTimeoutSeconds Sekunden ist kein Fenster erschienen." 'WARN'
    return $null
}

function Test-TargetAlreadyRunning {
    Param([Parameter(Mandatory = $true)][Object]$Target)

    $processName = Get-TargetProcessName -Target $Target
    if (-Not $processName) { return $false }
    return @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0
}

function Initialize-DesktopLayout {
    <#
        Legt pro aktivem Ziel einen virtuellen Desktop an und startet das Ziel
        dort. Ziel 1 nutzt den bestehenden Desktop 1, jedes weitere Ziel
        bekommt per Win+Strg+D einen neuen Desktop.

        Rueckgabe: Anzahl belegter Desktops.
    #>
    Param([Parameter(Mandatory = $true)][Object[]]$Targets)

    # Ein paar Anschlaege mehr als Ziele, damit der Anschlag sicher erreicht
    # wird, auch wenn noch Desktops aus einem frueheren Lauf offen sind.
    $resetSteps = [Math]::Max(12, $Targets.Count + 5)

    if ($ResetDesktopsOnStart) {
        Reset-DesktopLayout -Steps $resetSteps
    }
    else {
        # Win+Strg+D haengt den neuen Desktop immer ganz RECHTS an. Existieren
        # beim Start noch Desktops aus einem frueheren Lauf, liegen die Ziele
        # danach nicht mehr lueckenlos auf Desktop 1..N und die Zaehlung im
        # Rundlauf passt nicht mehr zur Realitaet.
        Write-Log "Hinweis: Der Layout-Aufbau geht davon aus, dass beim Start genau EIN virtueller Desktop existiert (Normalzustand nach dem Anmelden). Sind noch Desktops offen, 'resetDesktopsOnStart' aktivieren." 'WARN'
    }

    Reset-ToFirstDesktop -Steps $resetSteps

    $desktopIndex = 0
    foreach ($target in $Targets) {

        if ($desktopIndex -gt 0) {
            New-VirtualDesktop
        }
        $desktopIndex++

        Write-Log "Desktop $desktopIndex : richte Ziel '$($target.Name)' ein."

        if ((Test-TargetAlreadyRunning -Target $target) -and $target.Type -ne 'Url') {
            if ($RestartForPlacement) {
                $processName = Get-TargetProcessName -Target $target
                Write-Log "Ziel '$($target.Name)' laeuft bereits und kann per Hotkey nicht verschoben werden - wird gemaess 'restartForPlacement' beendet und auf Desktop $desktopIndex neu gestartet." 'WARN'
                Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            else {
                Write-Log "Ziel '$($target.Name)' laeuft bereits. Ein laufendes Fenster laesst sich per Hotkey NICHT auf einen anderen Desktop verschieben - es bleibt auf seinem bisherigen Desktop." 'WARN'
                Write-Log "Abhilfe: Programm vorher beenden, 'restartForPlacement' aktivieren, oder bei Single-Instance-Programmen 'Args' setzen (Notepad++: -multiInst)." 'WARN'
            }
        }

        $proc = Start-TargetOnCurrentDesktop -Target $target
        if (-Not $proc) { continue }

        if ($UseFullscreen) {
            # Das Fenster ist auf diesem Desktop allein und damit bereits im
            # Vordergrund - es muss also kein Fokus erkaempft werden. Zur
            # Sicherheit wird das trotzdem geprueft, bevor F11 rausgeht:
            # sonst landet der Tastendruck im falschen Fenster.
            Start-Sleep -Seconds 2
            $foregroundPid = Get-ForegroundProcessId
            if ($foregroundPid -eq $proc.Id) {
                Send-Fullscreen
                Write-Log "Ziel '$($target.Name)' auf Desktop $desktopIndex in den Vollbildmodus geschaltet."
            }
            else {
                Write-Log "Ziel '$($target.Name)': Vordergrundfenster gehoert zu PID $foregroundPid, erwartet war PID $($proc.Id). F11 wird NICHT gesendet, um kein fremdes Fenster umzuschalten." 'WARN'
            }
        }
    }

    Write-Log "Desktop-Layout aufgebaut: $desktopIndex Desktop(s) belegt."
    return $desktopIndex
}

# ============================================================
# Rundlauf
# ============================================================

function Invoke-DesktopCycle {
    <#
        Schaltet im Takt von $IntervalSeconds durch die Desktops.

        Weil Windows am letzten Desktop NICHT auf den ersten zurueckspringt,
        gibt es zwei Modi:
          Bounce - vor und zurueck (kein Sprung, ruhiges Bild; die mittleren
                   Desktops sind pro Durchgang zweimal zu sehen)
          Rewind - vorwaerts bis zum Ende, dann schnell zurueck auf Desktop 1
                   (gleiche Standzeit fuer alle, dafuer ein kurzes Durchblitzen)
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
    $direction = 1

    if ($MaxRuntimeSeconds -gt 0) {
        Write-Log "Rundlauf gestartet: $DesktopCount Desktops, Intervall $IntervalSeconds s, Modus $Mode, Laufzeitgrenze $MaxRuntimeSeconds s."
    }
    else {
        Write-Log "Rundlauf gestartet: $DesktopCount Desktops, Intervall $IntervalSeconds s, Modus $Mode, ohne Laufzeitgrenze."
    }

    while ($true) {

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

        if ($Mode -eq 'Bounce') {
            if ($position -ge $DesktopCount) { $direction = -1 }
            elseif ($position -le 1)         { $direction = 1 }

            if ($direction -eq 1) { Switch-DesktopRight; $position++ }
            else                  { Switch-DesktopLeft;  $position-- }
        }
        else {
            if ($position -ge $DesktopCount) {
                # Zurueck auf Desktop 1. Bewusst ohne Standzeit, damit die
                # uebersprungenen Desktops nicht als vollwertige Station
                # erscheinen.
                for ($i = 0; $i -lt ($DesktopCount - 1); $i++) {
                    Switch-DesktopLeft
                }
                $position = 1
            }
            else {
                Switch-DesktopRight
                $position++
            }
        }

        Write-Log "Aktive Desktop-Position laut Zaehlung: $position von $DesktopCount."
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

if ($CycleOnly) {
    Reset-ToFirstDesktop -Steps ([Math]::Max(12, $Targets.Count + 5))
    $desktopCount = $Targets.Count
    Write-Log "CycleOnly: Layout wird nicht neu aufgebaut, es werden $desktopCount bestehende Desktops angenommen."
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
