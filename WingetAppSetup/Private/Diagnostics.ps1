# The diagnostics bundle (-CollectDiagnostics): one .zip a teammate attaches to a GitHub issue after a
# failed run, with the latest run's logs and the state that decides whether winget works, and with
# account, computer and profile names and real accounts' SIDs replaced, since the issues are public.
# It changes nothing on the PC (no transcript, run lock, last-run.json, setup or elevation) and writes
# only the .zip; a source it cannot read is noted in README.txt. It runs before the 5.1 bootstrap, so
# this file and the helpers it reaches must stay Windows PowerShell 5.1-compatible: the account and
# elevation helpers (Elevation.ps1, EnvironmentPreflight.ps1), Get-OSArchitecture,
# Get-PendingRestartState, the WAU readers and Get-DefaultWindowsAppRuntimeRequirement
# (WauSupport.ps1), Get-MachineWingetCandidate, ProcessInvocation.ps1, Format-WingetExitCode,
# Format-RunRecordTime, Get-WindowsAppRuntimePin and the Write-* helpers.

<#
.SYNOPSIS
    Returns the command that makes a diagnostics bundle, for the failure notices to print.
.DESCRIPTION
    irm | iex cannot pass a switch, so the command downloads the installer from main into a script
    block and runs it with -CollectDiagnostics: any console, 5.1 or 7, elevated or not, and no
    execution policy change (a script block is not a script file).
.OUTPUTS
    [string]
#>
function Get-DiagnosticsCommandLine {
    return '& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics'
}

<#
.SYNOPSIS
    Says where to report a failed run and how to make the diagnostics bundle for it, after an early
    exit's notice and under the summary of a run that failed (1, 2 or 8). Runs under 5.1 too.
#>
function Write-InstallerReportHint {
    Write-Info 'To report this, open https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml and give the exit code, the installer build and a diagnostics bundle (or the log file).'
    Write-Info 'A diagnostics bundle is a .zip of the installer''s logs and the state of winget, App Installer and auto-updates on this PC, with account and computer names removed. Making one changes nothing. Run this in PowerShell (as administrator, for everything it can collect), then attach the file it names:'
    Write-Info ('    ' + (Get-DiagnosticsCommandLine))
    Write-WarningMessage 'That repository is public, and the log names this computer and the accounts that ran the installer: remove or redact the log''s header before attaching it. The bundle has those names removed already; look through it anyway.'
}

<#
.SYNOPSIS
    Reads a text file that another process may still be writing, at most its last MaxBytes.
.DESCRIPTION
    Read, write and delete sharing, so a log still held open can be read. The encoding comes from the
    BOM (UTF-8, UTF-16 LE or BE), else UTF-16 LE when the first characters have zero high bytes (an
    msiexec log), else UTF-8. A longer file is read from the end, where an installer log has its
    result, after a line saying how much was left out.
.PARAMETER Path
    The file.
.PARAMETER MaxBytes
    The most bytes to read. Default 4 MB.
.OUTPUTS
    [string]
#>
function Read-DiagnosticsTextFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [long]$MaxBytes = 4MB
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $length = $stream.Length
        $head = New-Object byte[] 4
        $headCount = $stream.Read($head, 0, 4)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $preamble = 0
        $twoByte = $false
        if ($headCount -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
            $encoding = [System.Text.Encoding]::Unicode
            $preamble = 2
            $twoByte = $true
        }
        elseif ($headCount -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
            $encoding = [System.Text.Encoding]::BigEndianUnicode
            $preamble = 2
            $twoByte = $true
        }
        elseif ($headCount -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $preamble = 3
        }
        elseif ($headCount -eq 4 -and $head[0] -ne 0 -and $head[1] -eq 0 -and $head[2] -ne 0 -and $head[3] -eq 0) {
            $encoding = [System.Text.Encoding]::Unicode
            $twoByte = $true
        }

        $start = [long]$preamble
        $note = $null
        if ($length - $preamble -gt $MaxBytes) {
            $start = $length - $MaxBytes
            if ($twoByte -and (($start - $preamble) % 2) -ne 0) {
                $start++
            }
            $note = '[The first {0} bytes of this file were left out; its last {1} bytes follow.]' -f ($start - $preamble), ($length - $start)
        }
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $count = [int]($length - $start)
        $buffer = New-Object byte[] $count
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($buffer, $offset, $count - $offset)
            if ($read -le 0) {
                break
            }
            $offset += $read
        }
        $text = $encoding.GetString($buffer, 0, $offset)
        if ($note) {
            $text = $note + [Environment]::NewLine + $text
        }
        return $text
    }
    finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
    Returns the last part of a Windows path ('C:\Users\jdoe' gives 'jdoe'), on any OS.
.DESCRIPTION
    Split-Path splits only on the separators of the OS it runs on, and these paths are always
    Windows paths, also when tests read them on Linux.
#>
function Get-DiagnosticsPathLeaf {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    $trimmed = $Path.Trim().TrimEnd('\', '/')
    $index = $trimmed.LastIndexOfAny([char[]]@('\', '/'))
    return $trimmed.Substring($index + 1)
}

<#
.SYNOPSIS
    Turns the yyyyMMdd-HHmmss stamp in an installer log's name into a time, or $null.
#>
function ConvertFrom-DiagnosticsLogStamp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Stamp
    )

    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($Stamp, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

<#
.SYNOPSIS
    Picks the logs of the latest run from the installer's logs folder.
.DESCRIPTION
    By the names the installer gives its logs (see Remove-OldInstallerLog):
      - Transcripts (install-<time>[-bootstrap|-rmm|-userphase].log; -whatif ones left out): the
        newest and every other started up to WindowMinutes before it, at most MaximumTranscripts,
        since one run can write four. The one last-run.json names is kept too.
      - Installer logs (winget-*, pwsh-msi-*, wau-msi-*), from the oldest transcript kept on, at
        most MaximumInstallerLogs, newest first.
      - last-run.json.
.PARAMETER LogDirectory
    The logs folder.
.PARAMETER WindowMinutes
    How long before the newest transcript another transcript may start and still belong to the
    latest run. Default 60.
.PARAMETER MaximumTranscripts
    Default 6.
.PARAMETER MaximumInstallerLogs
    Default 40.
.OUTPUTS
    [pscustomobject] Transcripts and InstallerLogs ([System.IO.FileInfo[]], oldest first), RunRecord
    (last-run.json, or $null) and Files (every file in the folder). Throws when the folder cannot be
    listed.
#>
function Select-DiagnosticsLogFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [int]$WindowMinutes = 60,

        [Parameter(Mandatory = $false)]
        [int]$MaximumTranscripts = 6,

        [Parameter(Mandatory = $false)]
        [int]$MaximumInstallerLogs = 40
    )

    $files = @(Get-ChildItem -LiteralPath $LogDirectory -File -Force -ErrorAction Stop)
    $transcripts = @()
    $installerLogs = @()
    $runRecord = $null
    foreach ($file in $files) {
        if ($file.Name -match '^install-(?<stamp>\d{8}-\d{6})(?:-bootstrap|-rmm|-userphase)?\.log$') {
            $time = ConvertFrom-DiagnosticsLogStamp -Stamp $Matches['stamp']
            if ($null -ne $time) {
                $transcripts += [pscustomobject]@{ File = $file; Stamp = $Matches['stamp']; Time = $time }
            }
        }
        elseif ($file.Name -match '^(?:winget-(?:install|upgrade|uninstall|repair)-.+|pwsh-msi|wau-msi-(?:install|uninstall))-(?<stamp>\d{8}-\d{6})(?:-\d+)?\.log$') {
            $installerLogs += [pscustomobject]@{ File = $file; Stamp = $Matches['stamp'] }
        }
        elseif ($file.Name -eq 'last-run.json') {
            $runRecord = $file
        }
    }

    $newestFirst = @($transcripts | Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true })
    $selected = @()
    if ($newestFirst.Count -gt 0) {
        $windowStart = $newestFirst[0].Time.AddMinutes(-$WindowMinutes)
        $selected = @($newestFirst | Where-Object { $_.Time -ge $windowStart } | Select-Object -First $MaximumTranscripts)
    }

    if ($null -ne $runRecord) {
        $namedTranscript = $null
        try {
            $record = (Read-DiagnosticsTextFile -Path $runRecord.FullName -MaxBytes 1MB) | ConvertFrom-Json
            if ($record -and $record.transcriptPath) {
                $namedTranscript = Get-DiagnosticsPathLeaf -Path ([string]$record.transcriptPath)
            }
        }
        catch {
            # A record that cannot be read is still bundled as it is.
            $namedTranscript = $null
        }
        if ($namedTranscript) {
            $alreadySelected = @($selected | Where-Object { $_.File.Name -eq $namedTranscript }).Count -gt 0
            if (-not $alreadySelected) {
                $selected += @($transcripts | Where-Object { $_.File.Name -eq $namedTranscript })
            }
        }
    }

    $selectedLogs = @()
    if ($selected.Count -gt 0) {
        $oldestStamp = @($selected | Sort-Object -Property Stamp | Select-Object -First 1)[0].Stamp
        $selectedLogs = @($installerLogs | Where-Object { [string]::CompareOrdinal($_.Stamp, $oldestStamp) -ge 0 } |
                Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true } |
                Select-Object -First $MaximumInstallerLogs)
    }

    return [pscustomobject]@{
        Transcripts   = @($selected | Sort-Object -Property Stamp, @{ Expression = { $_.File.Name } } | ForEach-Object { $_.File })
        InstallerLogs = @($selectedLogs | Sort-Object -Property Stamp, @{ Expression = { $_.File.Name } } | ForEach-Object { $_.File })
        RunRecord     = $runRecord
        Files         = $files
    }
}

<#
.SYNOPSIS
    Reads the values of a registry key as name/value pairs, or $null when the key does not exist.
.DESCRIPTION
    A seam for the bundle's registry reads (mocked in tests). Throws when the key exists but cannot
    be read.
.PARAMETER Path
    A registry provider path, such as 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] or $null.
#>
function Get-DiagnosticsRegistryValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    $values = [ordered]@{}
    foreach ($property in @($item.PSObject.Properties)) {
        if (@('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') -contains $property.Name) {
            continue
        }
        $values[$property.Name] = $property.Value
    }
    return $values
}

<#
.SYNOPSIS
    Lists the user profiles on this PC, each one's SID and folder, from ProfileList (which every
    account can read), so the redaction knows the account and folder names. Best-effort.
.OUTPUTS
    [pscustomobject[]] Sid and ProfilePath.
#>
function Get-DiagnosticsProfileList {
    try {
        $keys = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop)
    }
    catch {
        return
    }
    foreach ($key in $keys) {
        $profilePath = $null
        try {
            $profilePath = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath
        }
        catch {
            $profilePath = $null
        }
        [pscustomobject]@{ Sid = [string]$key.PSChildName; ProfilePath = $profilePath }
    }
}

<#
.SYNOPSIS
    Returns the account name of a SID (DOMAIN\user), or $null.
.DESCRIPTION
    A seam (mocked in tests); $null when the SID cannot be translated (a deleted account, a domain
    controller out of reach, off Windows).
#>
function Get-DiagnosticsSidAccountName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    try {
        $identifier = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $identifier.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Collects the names on this PC that identify it or a person: what the bundle's redaction removes.
.DESCRIPTION
    The environment (COMPUTERNAME, USERNAME, USERDOMAIN, USERDNSDOMAIN), the host name and DNS
    domain, this run's accounts, the accounts with a profile (folder names, and account names for
    real accounts' SIDs: S-1-5-21-... and S-1-12-1-...), and the registered owner and organization,
    which installers copy into their logs. Best-effort.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, or $null.
.OUTPUTS
    [pscustomobject] ComputerNames, DnsDomains, Domains, Users and Organizations ([string[]]; not
    yet filtered, see New-DiagnosticsRedactionMap).
#>
function Get-DiagnosticsIdentityHint {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $computers = @($env:COMPUTERNAME)
    $dnsDomains = @($env:USERDNSDOMAIN)
    $domains = @($env:USERDOMAIN)
    $users = @($env:USERNAME)
    $organizations = @()
    try {
        $computers += [System.Net.Dns]::GetHostName()
    }
    catch {
    }
    try {
        $dnsDomains += [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    }
    catch {
    }

    $accounts = @()
    if ($AccountContext) {
        $accounts += @([string]$AccountContext.ProcessUser, [string]$AccountContext.SessionUser)
    }
    foreach ($userProfile in @(Get-DiagnosticsProfileList)) {
        if ("$($userProfile.Sid)" -notmatch '^S-1-(?:5-21|12-1)-') {
            continue
        }
        if ($userProfile.ProfilePath) {
            $users += Get-DiagnosticsPathLeaf -Path ([string]$userProfile.ProfilePath)
        }
        $accounts += Get-DiagnosticsSidAccountName -Sid $userProfile.Sid
    }
    foreach ($account in $accounts) {
        if ([string]::IsNullOrWhiteSpace($account)) {
            continue
        }
        $parts = ([string]$account).Split('\')
        if ($parts.Count -ge 2) {
            $domains += $parts[0]
            $users += $parts[$parts.Count - 1]
        }
        else {
            $users += $parts[0]
        }
    }

    try {
        $windows = Get-DiagnosticsRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($windows) {
            $users += [string]$windows['RegisteredOwner']
            $organizations += [string]$windows['RegisteredOrganization']
        }
    }
    catch {
    }

    return [pscustomobject]@{
        ComputerNames = @($computers)
        DnsDomains    = @($dnsDomains)
        Domains       = @($domains)
        Users         = @($users)
        Organizations = @($organizations)
    }
}

<#
.SYNOPSIS
    Builds the replacements that remove names from the bundle's text files.
.DESCRIPTION
    Get-DiagnosticsIdentityHint's names, plus those the files carry: a transcript header's Username,
    RunAs User and Machine; an msiexec log's LogonUser, USERNAME, COMPANYNAME and ComputerName; the
    accounts Get-AppxPackage names next to a SID. Built-in accounts and groups, the default profile
    folders, generic owner names and names under two characters stay. Every other name gets one
    numbered placeholder for all files (<computer1>, <dns-domain1>, <domain1>, <user1>,
    <organization1>); a computer account (PC$) counts as a computer. Real accounts' SIDs get
    <sid1>... for their identifying part (the RID stays); well-known SIDs stay.
.PARAMETER IdentityHint
    Get-DiagnosticsIdentityHint's result, or $null.
.PARAMETER Text
    The text of every file in the bundle.
.OUTPUTS
    [pscustomobject] Names (Value and Placeholder, longest value first) and Sids (Value, the
    identifying part of a SID such as 'S-1-5-21-1-2-3', and Placeholder).
#>
function New-DiagnosticsRedactionMap {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$IdentityHint,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Text = @()
    )

    $computers = New-Object System.Collections.Generic.List[string]
    $dnsDomains = New-Object System.Collections.Generic.List[string]
    $domains = New-Object System.Collections.Generic.List[string]
    $users = New-Object System.Collections.Generic.List[string]
    $organizations = New-Object System.Collections.Generic.List[string]
    if ($IdentityHint) {
        foreach ($value in @($IdentityHint.ComputerNames)) { $computers.Add([string]$value) }
        foreach ($value in @($IdentityHint.DnsDomains)) { $dnsDomains.Add([string]$value) }
        foreach ($value in @($IdentityHint.Domains)) { $domains.Add([string]$value) }
        foreach ($value in @($IdentityHint.Users)) { $users.Add([string]$value) }
        foreach ($value in @($IdentityHint.Organizations)) { $organizations.Add([string]$value) }
    }

    $accounts = New-Object System.Collections.Generic.List[string]
    $sidAuthorities = New-Object System.Collections.Generic.List[string]
    # CultureInvariant: without it, ignoring case follows the current culture, and on a Turkish or
    # Azerbaijani Windows 'i' and 'I' are not the same letter (see ConvertTo-RedactedDiagnosticText).
    $multiline = [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    foreach ($content in @($Text)) {
        if ([string]::IsNullOrEmpty($content)) {
            continue
        }
        foreach ($match in [regex]::Matches($content, '^[ \t]*(?:Username|RunAs User):[ \t]*(?<account>\S[^\r\n]*?)[ \t]*\r?$', $multiline)) {
            $accounts.Add($match.Groups['account'].Value)
        }
        foreach ($match in [regex]::Matches($content, '^[ \t]*Machine:[ \t]*(?<computer>[^\s(]+)', $multiline)) {
            $computers.Add($match.Groups['computer'].Value)
        }
        $msiPatterns = @(
            'Property\([A-Z]\):[ \t]*(?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName)[ \t]*=[ \t]*(?<value>[^\r\n]*?)[ \t]*\r?$',
            'PROPERTY CHANGE: (?:Adding|Modifying) (?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName) property\. Its (?:current )?value is ''(?<value>[^''\r\n]*)''',
            'PROPERTY CHANGE: Modifying (?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName) property\. Its current value is ''[^''\r\n]*''\. Its new value: ''(?<value>[^''\r\n]*)'''
        )
        foreach ($pattern in $msiPatterns) {
            foreach ($match in [regex]::Matches($content, $pattern, $multiline)) {
                $value = $match.Groups['value'].Value
                switch ($match.Groups['name'].Value.ToUpperInvariant()) {
                    'COMPANYNAME' { $organizations.Add($value) }
                    'COMPUTERNAME' { $computers.Add($value) }
                    default { $accounts.Add($value) }
                }
            }
        }
        foreach ($match in [regex]::Matches($content, '\bS-1-\d+(?:-\d+)+ \[(?<account>[^\]\r\n]+)\]', $multiline)) {
            $accounts.Add($match.Groups['account'].Value)
        }
        foreach ($match in [regex]::Matches($content, '\b(?<authority>S-1-5-21-\d+-\d+-\d+|S-1-12-1-\d+-\d+-\d+-\d+)(?!\d)', $multiline)) {
            $sidAuthorities.Add($match.Groups['authority'].Value)
        }
    }
    foreach ($account in $accounts) {
        if ([string]::IsNullOrWhiteSpace($account)) {
            continue
        }
        $parts = $account.Trim().Split('\')
        if ($parts.Count -ge 2) {
            $domains.Add($parts[0])
            $users.Add($parts[$parts.Count - 1])
        }
        else {
            $users.Add($parts[0])
        }
    }
    # A computer account (PC-4711$, the Username of a SYSTEM run's transcript) is the computer.
    foreach ($user in @($users)) {
        if ($user -and $user.Trim().EndsWith('$')) {
            $computers.Add($user.Trim().TrimEnd('$'))
        }
    }

    $kept = @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'LocalSystem', 'LocalService', 'NetworkService', 'NT AUTHORITY',
        'NT SERVICE', 'NT VIRTUAL MACHINE', 'BUILTIN', 'WORKGROUP', 'AzureAD', 'MicrosoftAccount', 'Window Manager',
        'Font Driver Host', 'IIS APPPOOL', 'Administrator', 'Administrators', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount',
        'defaultuser0', 'Public', 'Default', 'Default User', 'All Users', 'Users', 'Everyone', 'Authenticated Users',
        'INTERACTIVE', 'Unknown user', 'Windows User', 'User', 'Admin', 'Owner', 'localhost')
    $seen = @{}
    $names = New-Object System.Collections.Generic.List[object]
    $categories = @(
        [pscustomobject]@{ List = $computers; Prefix = 'computer' },
        [pscustomobject]@{ List = $dnsDomains; Prefix = 'dns-domain' },
        [pscustomobject]@{ List = $domains; Prefix = 'domain' },
        [pscustomobject]@{ List = $users; Prefix = 'user' },
        [pscustomobject]@{ List = $organizations; Prefix = 'organization' }
    )
    foreach ($category in $categories) {
        $number = 0
        foreach ($rawValue in $category.List) {
            if ($null -eq $rawValue) {
                continue
            }
            $value = $rawValue.Trim().Trim('"', "'").Trim()
            if ($category.Prefix -ne 'organization' -and $category.Prefix -ne 'dns-domain') {
                $value = $value.TrimEnd('$')
            }
            if ($value.Length -lt 2 -or $value -notmatch '\p{L}' -or $value.Contains('<') -or $value.Contains('>')) {
                continue
            }
            $key = $value.ToUpperInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $isKept = $false
            foreach ($keptName in $kept) {
                if ([string]::Equals($keptName, $value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isKept = $true
                    break
                }
            }
            if ($isKept) {
                continue
            }
            $seen[$key] = $true
            $number++
            $names.Add([pscustomobject]@{ Value = $value; Placeholder = ('<{0}{1}>' -f $category.Prefix, $number) })
        }
    }

    $sids = New-Object System.Collections.Generic.List[object]
    $seenSids = @{}
    foreach ($authority in $sidAuthorities) {
        $key = $authority.ToUpperInvariant()
        if ($seenSids.ContainsKey($key)) {
            continue
        }
        $seenSids[$key] = $true
        $prefix = 'S-1-5-21-'
        if ($key.StartsWith('S-1-12-1-')) {
            $prefix = 'S-1-12-1-'
        }
        $sids.Add([pscustomobject]@{ Value = $authority; Placeholder = ('{0}<sid{1}>' -f $prefix, ($sids.Count + 1)) })
    }

    return [pscustomobject]@{
        Names = @($names | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true })
        Sids  = @($sids | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true })
    }
}

<#
.SYNOPSIS
    Removes account names, computer names, profile folders, the SIDs of real accounts and email
    addresses from a text, for the public bundle.
.DESCRIPTION
    In this order:
      1. An msiexec log's LogonUser, USERNAME, COMPANYNAME, ComputerName and UserSID property lines
         keep the name and lose the value ('<redacted>').
      2. Email addresses (user principal names) become <email>.
      3. Every name in the map (New-DiagnosticsRedactionMap) becomes its placeholder, wherever it
         stands on its own (not inside a longer word), in any letter case, whatever the culture.
      4. The identifying part of every S-1-5-21-... and S-1-12-1-... SID becomes its placeholder,
         or <sid> when the map does not know it. Well-known SIDs stay.
      5. The folder name after X:\Users\ (or X:\Documents and Settings\) that is still there
         becomes <user>, except Public, Default, Default User and All Users.
.PARAMETER Text
    The text.
.PARAMETER Map
    New-DiagnosticsRedactionMap's result.
.OUTPUTS
    [string]
#>
function ConvertTo-RedactedDiagnosticText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [object]$Map
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    # CultureInvariant: without it, ignoring case follows the current culture, and on a Turkish or
    # Azerbaijani Windows 'MIKE' would not match 'mike' (dotted and dotless i), so a name would stay
    # in the bundle in every letter case but the one the map has.
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $multiline = [System.Text.RegularExpressions.RegexOptions]::Multiline -bor $ignoreCase

    $result = [regex]::Replace($Text, '^(?<prefix>.*?Property\([A-Z]\):[ \t]*(?:LogonUser|USERNAME|COMPANYNAME|ComputerName|UserSID)[ \t]*=[ \t]*)\S[^\r\n]*?(?<end>\r?)$', '${prefix}<redacted>${end}', $multiline)

    # Email addresses first: a name inside one would otherwise break it up before it is found.
    $result = [regex]::Replace($result, '\b[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}\b', '<email>', $ignoreCase)

    # One pass for all the names, longest first, so a placeholder already written is never matched
    # again by a shorter name.
    $nameLookup = @{}
    $alternatives = @()
    foreach ($name in @($Map.Names)) {
        $key = ([string]$name.Value).ToUpperInvariant()
        if (-not $nameLookup.ContainsKey($key)) {
            $nameLookup[$key] = [string]$name.Placeholder
            $alternatives += [regex]::Escape([string]$name.Value)
        }
    }
    if ($alternatives.Count -gt 0) {
        $nameRegex = New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:' + ($alternatives -join '|') + ')(?![\p{L}\p{N}])'), $ignoreCase)
        $nameEvaluator = [System.Text.RegularExpressions.MatchEvaluator]({
                param ($match)
                $nameLookup[$match.Value.ToUpperInvariant()]
            }.GetNewClosure())
        $result = $nameRegex.Replace($result, $nameEvaluator)
    }

    $sidLookup = @{}
    foreach ($sid in @($Map.Sids)) {
        $sidLookup[([string]$sid.Value).ToUpperInvariant()] = [string]$sid.Placeholder
    }
    $sidRegex = New-Object System.Text.RegularExpressions.Regex('\b(?<authority>S-1-5-21-\d+-\d+-\d+|S-1-12-1-\d+-\d+-\d+-\d+)(?!\d)', $ignoreCase)
    $sidEvaluator = [System.Text.RegularExpressions.MatchEvaluator]({
            param ($match)
            $authority = $match.Groups['authority'].Value.ToUpperInvariant()
            if ($sidLookup.ContainsKey($authority)) {
                return $sidLookup[$authority]
            }
            if ($authority.StartsWith('S-1-12-1-')) {
                return 'S-1-12-1-<sid>'
            }
            return 'S-1-5-21-<sid>'
        }.GetNewClosure())
    $result = $sidRegex.Replace($result, $sidEvaluator)

    $profilePattern = '(?<prefix>\b[A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)(?!(?:Public|Default|Default User|All Users)(?:[\\/"''\s,;)\]]|$))[^\\/:*?"<>|\r\n]+'
    $result = [regex]::Replace($result, $profilePattern, '${prefix}<user>', $multiline)

    return $result
}

<#
.SYNOPSIS
    Returns the path of one of Windows' special folders, or $null.
.DESCRIPTION
    A seam over [Environment]::GetFolderPath (mocked in tests).
.PARAMETER Name
    A System.Environment+SpecialFolder name, such as 'Desktop' or 'CommonDocuments'.
#>
function Get-DiagnosticsSpecialFolder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $path = [Environment]::GetFolderPath($Name)
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }
    return $path
}

<#
.SYNOPSIS
    Lists the folders to save the bundle in, best first: ones the signed-in user can open.
.DESCRIPTION
    The user's Desktop for a run as that user; Public Documents for a run as SYSTEM or another
    account, whose Desktop the user cannot open; this process's temp folder last. Folders that do
    not exist are left out.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, or $null.
.OUTPUTS
    [string[]]
#>
function Get-DiagnosticsBundleDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $names = @()
    if (-not ($AccountContext -and ($AccountContext.IsSystem -or $AccountContext.IsCrossUserElevation))) {
        $names += 'Desktop'
    }
    $names += 'CommonDocuments'
    $folders = @()
    foreach ($name in $names) {
        $path = Get-DiagnosticsSpecialFolder -Name $name
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
            $folders += $path
        }
    }
    $temp = [System.IO.Path]::GetTempPath()
    if ($temp -and (Test-Path -LiteralPath $temp -PathType Container)) {
        $folders += $temp
    }
    return @($folders | Select-Object -Unique)
}

<#
.SYNOPSIS
    Says, in a few words, how the account that runs this is elevated.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, or $null.
.PARAMETER IsAdmin
    Whether this process is elevated.
.OUTPUTS
    [string] 'SYSTEM', 'cross-user (...)', 'same-user, elevated' or 'same-user, not elevated'.
#>
function Get-DiagnosticsElevationStyle {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdmin
    )

    if ($AccountContext -and $AccountContext.IsSystem) {
        return 'SYSTEM'
    }
    if ($AccountContext -and $AccountContext.IsCrossUserElevation) {
        return 'cross-user (elevated as another account than the signed-in user)'
    }
    if ($IsAdmin) {
        return 'same-user, elevated'
    }
    return 'same-user, not elevated'
}

<#
.SYNOPSIS
    Formats the values of a registry key for the bundle: 'name = value' lines, or one line saying
    the key is not there.
.PARAMETER Path
    The registry key.
#>
function Format-DiagnosticsRegistryKey {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $values = Get-DiagnosticsRegistryValue -Path $Path
    }
    catch {
        return @("  not read: $($_.Exception.Message)")
    }
    if ($null -eq $values) {
        return @('  not configured (no such key)')
    }
    if ($values.Count -eq 0) {
        return @('  no values')
    }
    $lines = @()
    foreach ($name in $values.Keys) {
        $lines += ('  {0} = {1}' -f $name, (@($values[$name]) -join '; '))
    }
    return $lines
}

<#
.SYNOPSIS
    Whether this is a 32-bit process on 64-bit Windows (WOW64), such as an RMM agent's PowerShell.
.DESCRIPTION
    A seam (mocked in tests). In such a process, HKLM\SOFTWARE reads go to its 32-bit view
    (WOW6432Node) and System32 to SysWOW64.
.OUTPUTS
    [bool]
#>
function Test-DiagnosticsWow64Process {
    return ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
}

<#
.SYNOPSIS
    Says what a bundle made from a 32-bit PowerShell on 64-bit Windows gets wrong, and how to make
    a correct one.
.DESCRIPTION
    -CollectDiagnostics does not relaunch, so the 64-bit HKLM\SOFTWARE entries (PowerShell 7's
    InstalledVersions, WAU's entries, the restart keys) read as missing. Group Policy keys and the
    AppX queries (run through Sysnative) are not affected.
.OUTPUTS
    [string]
#>
function Get-DiagnosticsWow64Note {
    return 'This PowerShell is 32-bit on 64-bit Windows, so registry values under HKLM\SOFTWARE were read from its 32-bit view (WOW6432Node): in system.txt, PowerShell 7, Winget-AutoUpdate and the pending restart can read as missing when they are there. For a correct report, run the command again from 64-bit PowerShell (from a 32-bit RMM agent, %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe).'
}

<#
.SYNOPSIS
    Lists the PowerShell 7 installs Windows has registered: each one's version and folder.
.DESCRIPTION
    A seam (mocked in tests) over HKLM\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions, where the
    PowerShell 7 MSI registers each install. Nothing when the key does not exist; throws when it
    cannot be read.
.OUTPUTS
    [pscustomobject[]] SemanticVersion and InstallLocation.
#>
function Get-DiagnosticsPowerShellInstall {
    $root = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    if (-not (Test-Path -LiteralPath $root)) {
        return
    }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            SemanticVersion = [string]$entry.SemanticVersion
            InstallLocation = [string]$entry.InstallLocation
        }
    }
}

<#
.SYNOPSIS
    Builds system.txt: Windows, the account that ran the collection, PowerShell and its execution
    policy, App Installer's and the Microsoft Store's Group Policy, a pending restart, and
    Winget-AutoUpdate.
.DESCRIPTION
    Every part is read on its own: one that fails says so and the rest is still read. Read-only.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, or $null.
.PARAMETER IsAdmin
    Whether this process is elevated.
.OUTPUTS
    [string[]] The lines.
#>
function Get-DiagnosticsSystemReport {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdmin
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('== Collection ==')
    $lines.Add(('Collected: {0}' -f (Format-RunRecordTime -Time ([DateTime]::UtcNow))))
    $buildId = 'unknown'
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $lines.Add("Collected by installer build: $buildId")
    $processBits = '32-bit'
    if ([Environment]::Is64BitProcess) {
        $processBits = '64-bit'
    }
    $osBits = '32-bit'
    if ([Environment]::Is64BitOperatingSystem) {
        $osBits = '64-bit'
    }
    $lines.Add(('PowerShell: {0} ({1}), {2} process on {3} Windows' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $processBits, $osBits))
    if (Test-DiagnosticsWow64Process) {
        $lines.Add(('Note: ' + (Get-DiagnosticsWow64Note)))
    }

    $lines.Add('')
    $lines.Add('== Windows ==')
    try {
        $windows = Get-DiagnosticsRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($windows) {
            $build = [string]$windows['CurrentBuild']
            if ($null -ne $windows['UBR']) {
                $build = '{0}.{1}' -f $build, $windows['UBR']
            }
            $lines.Add(('Product: {0} ({1}, {2})' -f $windows['ProductName'], $windows['EditionID'], $windows['InstallationType']))
            $lines.Add(('Version: {0}' -f $windows['DisplayVersion']))
            $lines.Add("Build: $build")
        }
        else {
            $lines.Add('Version key not found')
        }
    }
    catch {
        $lines.Add("Version not read: $($_.Exception.Message)")
    }
    $lines.Add("OS version: $([Environment]::OSVersion.VersionString)")
    $architecture = $null
    try {
        $architecture = Get-OSArchitecture
    }
    catch {
        $architecture = $env:PROCESSOR_ARCHITEW6432
        if (-not $architecture) {
            $architecture = $env:PROCESSOR_ARCHITECTURE
        }
    }
    $lines.Add("OS architecture: $architecture")
    $lines.Add(('Language: {0} (display {1})' -f [System.Globalization.CultureInfo]::CurrentCulture.Name, [System.Globalization.CultureInfo]::CurrentUICulture.Name))

    $lines.Add('')
    $lines.Add('== Accounts ==')
    $processSid = $null
    try {
        $processSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        $processSid = $null
    }
    $processUser = 'unknown'
    $sessionUser = 'nobody signed in, or unknown'
    if ($AccountContext -and $AccountContext.ProcessUser) {
        $processUser = [string]$AccountContext.ProcessUser
    }
    if ($AccountContext -and $AccountContext.SessionUser) {
        $sessionUser = [string]$AccountContext.SessionUser
        $sessionSid = Get-AccountSid -AccountName $sessionUser
        if ($sessionSid) {
            $sessionUser = '{0} ({1})' -f $sessionUser, $sessionSid
        }
    }
    if ($processSid) {
        $processUser = '{0} ({1})' -f $processUser, $processSid
    }
    $elevated = 'no'
    if ($IsAdmin) {
        $elevated = 'yes'
    }
    $lines.Add("This collection ran as: $processUser, elevated: $elevated")
    $lines.Add("Signed-in user (console session): $sessionUser")
    $lines.Add("Elevation style: $(Get-DiagnosticsElevationStyle -AccountContext $AccountContext -IsAdmin $IsAdmin)")
    $lines.Add('(The transcripts'' headers show the accounts of the runs themselves: Username is the signed-in user, RunAs User the account that ran the installer.)')

    $lines.Add('')
    $lines.Add('== PowerShell ==')
    try {
        $installed = @(Get-DiagnosticsPowerShellInstall)
        foreach ($install in $installed) {
            $lines.Add(('PowerShell 7 installed: {0} at {1}' -f $install.SemanticVersion, $install.InstallLocation))
        }
        if ($installed.Count -eq 0) {
            $lines.Add('PowerShell 7 installed: none registered')
        }
    }
    catch {
        $lines.Add("PowerShell 7 installed: not read: $($_.Exception.Message)")
    }
    $lines.Add(('Execution policy, this PowerShell ({0}):' -f $PSVersionTable.PSEdition))
    try {
        foreach ($policy in @(Get-ExecutionPolicy -List)) {
            $lines.Add(('  {0} = {1}' -f $policy.Scope, $policy.ExecutionPolicy))
        }
    }
    catch {
        $lines.Add("  not read: $($_.Exception.Message)")
    }
    $lines.Add('Execution policy, Group Policy keys:')
    foreach ($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell', 'HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore')) {
        $lines.Add("  $key")
        foreach ($line in @(Format-DiagnosticsRegistryKey -Path $key)) {
            $lines.Add('  ' + $line)
        }
    }

    $lines.Add('')
    $lines.Add('== App Installer Group Policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller) ==')
    foreach ($line in @(Format-DiagnosticsRegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller')) {
        $lines.Add($line)
    }
    $lines.Add('')
    $lines.Add('== Microsoft Store Group Policy (HKLM\SOFTWARE\Policies\Microsoft\WindowsStore) ==')
    foreach ($line in @(Format-DiagnosticsRegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore')) {
        $lines.Add($line)
    }

    $lines.Add('')
    $lines.Add('== Pending restart ==')
    try {
        $restart = Get-PendingRestartState
        $lines.Add(('Component Based Servicing RebootPending: {0}' -f [bool]$restart.ComponentServicing))
        $lines.Add(('Windows Update RebootRequired: {0}' -f [bool]$restart.WindowsUpdate))
        $renames = @($restart.FileRenames)
        $lines.Add(('File replacements queued for the next restart: {0}' -f $renames.Count))
        foreach ($rename in ($renames | Select-Object -First 50)) {
            $lines.Add("  $rename")
        }
    }
    catch {
        $lines.Add("Not read: $($_.Exception.Message)")
    }

    # What this installer installs when the framework is missing, and its fallback requirement; the
    # packages are in appx.txt, the run's 'Windows App Runtime:' line in its transcript.
    $lines.Add('')
    $lines.Add('== Windows App Runtime ==')
    try {
        $runtimePin = Get-WindowsAppRuntimePin
        $lines.Add(('Pinned by this installer build: Windows App Runtime {0}, {1} {2} (installed for all users when a run finds the framework missing)' -f $runtimePin.Release, $runtimePin.FrameworkName, $runtimePin.FrameworkVersion))
        $lines.Add(('Built-in requirement (used when the latest winget release''s cannot be read): {0}' -f (Format-WindowsAppRuntimeRequirement -Frameworks @((Get-DefaultWindowsAppRuntimeRequirement).Frameworks))))
    }
    catch {
        $lines.Add("Not read: $($_.Exception.Message)")
    }
    $lines.Add('Packages registered and provisioned on this PC: appx.txt. The run''s ''Windows App Runtime:'' and ''Auto-updates:'' lines: its transcript in logs\.')

    $lines.Add('')
    $lines.Add('== Winget-AutoUpdate ==')
    try {
        $wau = Get-InstalledWauInfo
        if ($wau.Version -or $wau.ProductCode) {
            $lines.Add(('Installed: version {0}, MSI product code {1}' -f $wau.Version, $wau.ProductCode))
        }
        else {
            $lines.Add('Installed: no')
        }
    }
    catch {
        $lines.Add("Installed version not read: $($_.Exception.Message)")
    }
    try {
        $health = Get-WauTaskHealth
        if ($health.Exists) {
            $lastRun = 'never'
            if ($health.LastRunTime) {
                $lastRun = '{0:yyyy-MM-dd HH:mm}' -f $health.LastRunTime
            }
            $lastResult = 'unknown'
            if ($null -ne $health.LastTaskResult) {
                $lastResult = '0x{0:X8}' -f $health.LastTaskResult
            }
            $nextRun = 'none scheduled'
            if ($health.NextRunTime) {
                $nextRun = '{0:yyyy-MM-dd HH:mm}' -f $health.NextRunTime
            }
            $triggers = 'none'
            if (@($health.Triggers).Count -gt 0) {
                $triggers = @($health.Triggers) -join '; '
            }
            $lines.Add(('Task \WAU\Winget-AutoUpdate: state {0}; triggers: {1}; last run {2}, result {3}; next run {4}' -f $health.State, $triggers, $lastRun, $lastResult, $nextRun))
        }
        if ($health.Problem) {
            $lines.Add("Task problem: $($health.Problem)")
        }
        elseif ($health.Healthy) {
            $lines.Add('Task: will run')
        }
    }
    catch {
        $lines.Add("Task not read: $($_.Exception.Message)")
    }
    return $lines.ToArray()
}

<#
.SYNOPSIS
    Formats the result of one process the bundle ran: its command, outcome and output.
.PARAMETER Label
    The command as it should read, such as 'winget --version'.
.PARAMETER Result
    Invoke-ExternalProcess's (or Invoke-WingetProcess's) result.
.OUTPUTS
    [string[]]
#>
function Format-DiagnosticsProcessResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $lines = @()
    if ($Result.LaunchFailed) {
        $code = ''
        if ($null -ne $Result.LaunchErrorCode) {
            $code = ' (error {0})' -f $Result.LaunchErrorCode
        }
        $lines += ('{0}: could not be started{1}: {2}' -f $Label, $code, $Result.LaunchError)
    }
    elseif ($Result.TimedOut) {
        $lines += ('{0}: stopped at its time limit, after {1} seconds' -f $Label, $Result.DurationSeconds)
    }
    else {
        $exitText = 'unknown'
        if ($null -ne $Result.ExitCode) {
            $exitText = '{0} ({1})' -f (Format-WingetExitCode -ExitCode ([int]$Result.ExitCode)), $Result.ExitCode
        }
        $lines += ('{0}: exit {1}, {2} seconds' -f $Label, $exitText, $Result.DurationSeconds)
    }
    foreach ($line in @($Result.Output)) {
        $lines += ('  ' + $line)
    }
    return $lines
}

<#
.SYNOPSIS
    Builds winget.txt: `winget --version`, `winget --info` and whether winget can open the winget
    source, each with a time limit.
.DESCRIPTION
    The first two change nothing and need no network. The source check is Initialize-Winget's
    (Get-WingetSourceOpenArgument): it needs the network, and winget downloads the source first when
    it is missing. As SYSTEM the first machine-wide winget.exe runs. A winget that cannot be found
    or started is reported, not fatal: that is often why the bundle is made.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, or $null.
.OUTPUTS
    [string[]]
#>
function Get-DiagnosticsWingetReport {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $lines = @()
    $wingetPath = 'winget'
    if ($AccountContext -and $AccountContext.IsSystem) {
        $candidate = $null
        try {
            $candidate = @(Get-MachineWingetCandidate) | Select-Object -First 1
        }
        catch {
            $candidate = $null
        }
        if (-not $candidate) {
            return @('No machine-wide winget.exe was found (as SYSTEM, winget runs only by its full path from the App Installer package installed for this PC).')
        }
        $wingetPath = [string]$candidate.Path
        $lines += ('winget.exe for this PC (as SYSTEM): {0} (App Installer {1})' -f $candidate.Path, $candidate.Version)
    }
    $timeout = Get-ProcessTimeoutSeconds -Operation WingetVersion
    foreach ($argument in @('--version', '--info')) {
        $label = 'winget ' + $argument
        try {
            $result = Invoke-WingetProcess -ArgumentList @($argument) -TimeoutSeconds $timeout -WingetPath $wingetPath -Echo None -LogDirectory ''
            $lines += @(Format-DiagnosticsProcessResult -Label $label -Result $result)
        }
        catch {
            $lines += ('{0}: not run: {1}' -f $label, $_.Exception.Message)
        }
        $lines += ''
    }

    # Whether winget can open the source the installs use: `winget source update` exits 0 even when
    # its update fails, so only opening it tells (wgt-gq8.63).
    $openArguments = @(Get-WingetSourceOpenArgument)
    $label = 'winget ' + ($openArguments -join ' ')
    try {
        $result = Invoke-WingetProcess -ArgumentList $openArguments -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceOpen) -WingetPath $wingetPath -Echo None -LogDirectory ''
        $verdict = 'Winget source: not checked (winget did not answer)'
        if (-not $result.LaunchFailed -and -not $result.TimedOut) {
            if (Test-WingetSourceOpenExitCode -ExitCode $result.ExitCode) {
                $verdict = 'Winget source: opens'
            }
            else {
                $verdict = 'Winget source: CANNOT BE OPENED ({0})' -f (Format-WingetExitCode -ExitCode $result.ExitCode)
            }
        }
        $lines += $verdict
        $lines += @(Format-DiagnosticsProcessResult -Label $label -Result $result)
    }
    catch {
        $lines += ('{0}: not run: {1}' -f $label, $_.Exception.Message)
    }
    $lines += ''
    return $lines
}

<#
.SYNOPSIS
    Returns the Windows PowerShell to run the bundle's AppX queries in.
.DESCRIPTION
    Get-WindowsPowerShellPath, except in a 32-bit process on 64-bit Windows (an RMM agent's
    PowerShell), where System32 is redirected to the 32-bit SysWOW64 and the Appx cmdlets may not
    load: there the 64-bit one through %SystemRoot%\Sysnative.
.OUTPUTS
    [string]
#>
function Get-DiagnosticsWindowsPowerShellPath {
    if (Test-DiagnosticsWow64Process) {
        $sysnative = (Get-WindowsDirectoryPath) + '\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $sysnative -PathType Leaf) {
            return $sysnative
        }
    }
    return (Get-WindowsPowerShellPath)
}

<#
.SYNOPSIS
    Runs a script in Windows PowerShell, with a time limit, and returns the process result.
.DESCRIPTION
    As -EncodedCommand, so no quoting changes it, writing UTF-8, so non-ANSI names arrive intact
    (and can be redacted). The Appx and DISM cmdlets always load there. It starts without
    PSModulePath, so it builds its own default: inherited through Process.Start, PowerShell 7's
    module folders come first and their Utility and Security modules cannot load in 5.1
    (about_PSModulePath).
.PARAMETER Script
    The script.
.PARAMETER TimeoutSeconds
    The time limit. Default 120.
.OUTPUTS
    Invoke-ExternalProcess's result.
#>
function Invoke-DiagnosticsWindowsPowerShell {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    $prologue = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $ProgressPreference = ''SilentlyContinue''; '
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($prologue + $Script))
    return (Invoke-ExternalProcess -FilePath (Get-DiagnosticsWindowsPowerShellPath) -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -TimeoutSeconds $TimeoutSeconds -Echo None -RemoveEnvironmentVariable @('PSModulePath'))
}

<#
.SYNOPSIS
    Builds appx.txt: App Installer, the winget source package and the Windows App Runtime packages,
    registered and provisioned.
.DESCRIPTION
    In Windows PowerShell: Get-AppxPackage -AllUsers (with each account's install state; without
    administrator rights, this account's packages) for Microsoft.DesktopAppInstaller,
    Microsoft.Winget.Source (winget deploys it for each account; an account without it gets
    0x8A15000F SOURCE_DATA_MISSING) and Microsoft.WindowsAppRuntime.*, and
    Get-AppxProvisionedPackage -Online for App Installer and the Windows App Runtime; under
    PowerShell 7 also Windows PowerShell's execution policy, which decides whether the elevated
    relaunch can run.
.OUTPUTS
    [string[]]
#>
function Get-DiagnosticsAppxReport {
    $query = @'
$names = @('Microsoft.DesktopAppInstaller', 'Microsoft.Winget.Source', 'Microsoft.WindowsAppRuntime.*')
function Write-DiagnosticsPackage($package) {
    '{0} {1} {2} Status={3} Framework={4}' -f $package.Name, $package.Version, $package.Architecture, $package.Status, $package.IsFramework
    '  PackageFullName: {0}' -f $package.PackageFullName
    '  InstallLocation: {0}' -f $package.InstallLocation
    foreach ($user in @($package.PackageUserInformation)) {
        if ($user.UserSecurityId -and $user.UserSecurityId.Sid) {
            '  User: {0} {1}' -f $user.UserSecurityId.Sid, $user.InstallState
        }
        else {
            '  User: {0}' -f $user
        }
    }
}
'== Registered for any account (Get-AppxPackage -AllUsers) =='
try {
    $packages = @(foreach ($name in $names) { Get-AppxPackage -AllUsers -Name $name -ErrorAction Stop })
    if ($packages.Count -eq 0) { 'none' }
    foreach ($package in @($packages | Sort-Object Name, Version)) { Write-DiagnosticsPackage $package }
}
catch {
    'not read (it needs PowerShell started as administrator): ' + $_.Exception.Message
    ''
    '== Registered for this account (Get-AppxPackage) =='
    try {
        $packages = @(foreach ($name in $names) { Get-AppxPackage -Name $name -ErrorAction Stop })
        if ($packages.Count -eq 0) { 'none' }
        foreach ($package in @($packages | Sort-Object Name, Version)) { Write-DiagnosticsPackage $package }
    }
    catch {
        'not read: ' + $_.Exception.Message
    }
}
''
'== Provisioned for new accounts (Get-AppxProvisionedPackage -Online) =='
try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like 'Microsoft.DesktopAppInstaller*' -or $_.DisplayName -like 'Microsoft.WindowsAppRuntime*' })
    if ($provisioned.Count -eq 0) { 'none' }
    foreach ($package in @($provisioned | Sort-Object PackageName)) { '{0} {1} ({2})' -f $package.DisplayName, $package.Version, $package.PackageName }
}
catch {
    'not read (it needs PowerShell started as administrator): ' + $_.Exception.Message
}
'@
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $query += @'

''
'== Execution policy, Windows PowerShell (Get-ExecutionPolicy -List) =='
try {
    foreach ($policy in @(Get-ExecutionPolicy -List)) { '  {0} = {1}' -f $policy.Scope, $policy.ExecutionPolicy }
}
catch {
    'not read: ' + $_.Exception.Message
}
'@
    }

    $result = Invoke-DiagnosticsWindowsPowerShell -Script $query
    $lines = @()
    if ($result.LaunchFailed -or $result.TimedOut -or ($null -ne $result.ExitCode -and $result.ExitCode -ne 0)) {
        $lines += @(Format-DiagnosticsProcessResult -Label 'Windows PowerShell (AppX queries)' -Result $result)
        return $lines
    }
    return @($result.Output)
}

<#
.SYNOPSIS
    Returns the last lines of Winget-AutoUpdate's updates.log, with the path read, or why there are
    none.
.PARAMETER MaximumLines
    Default 400.
.OUTPUTS
    [string[]]
#>
function Get-DiagnosticsWauLogTail {
    param (
        [Parameter(Mandatory = $false)]
        [int]$MaximumLines = 400
    )

    $candidates = @()
    $logPath = Get-WauUpdatesLogPath
    if ($logPath) {
        $candidates += $logPath
    }
    if ($env:ProgramW6432) {
        $candidates += Join-Path $env:ProgramW6432 'Winget-AutoUpdate\logs\updates.log'
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $text = Read-DiagnosticsTextFile -Path $candidate -MaxBytes 1MB
        $allLines = @($text -split '\r?\n')
        if ($allLines.Count -gt 0 -and $allLines[$allLines.Count - 1] -eq '') {
            $allLines = @($allLines | Select-Object -First ($allLines.Count - 1))
        }
        $tail = @($allLines | Select-Object -Last $MaximumLines)
        return @(('The last {0} lines of {1}:' -f $tail.Count, $candidate)) + $tail
    }
    if ($candidates.Count -eq 0) {
        return @('Winget-AutoUpdate''s updates.log was not found: no Winget-AutoUpdate folder is known on this PC.')
    }
    return @(('Winget-AutoUpdate''s updates.log was not found ({0}).' -f (@($candidates) -join '; ')))
}

<#
.SYNOPSIS
    Writes the bundle: a .zip with one UTF-8 text file per entry.
.DESCRIPTION
    Created new (an existing file is never overwritten); a bundle that could not be written whole
    is deleted again. Uses System.IO.Compression, which Windows PowerShell 5.1 and PowerShell 7
    both have.
.PARAMETER Path
    The .zip to create.
.PARAMETER Entry
    The files: path inside the .zip (with / between folders) to text.
#>
function Save-DiagnosticsBundle {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entry
    )

    Add-Type -AssemblyName System.IO.Compression
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $fileStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $written = $false
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in @($Entry.Keys)) {
                $zipEntry = $archive.CreateEntry([string]$name, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $zipEntry.Open()
                try {
                    $bytes = $utf8.GetBytes([string]$Entry[$name])
                    $entryStream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        $written = $true
    }
    finally {
        $fileStream.Dispose()
        if (-not $written) {
            try {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            catch {
            }
        }
    }
}

<#
.SYNOPSIS
    Returns the user phase's folder of the account making the bundle, %LOCALAPPDATA%\winget-app-setup
    (user-phase.json and its logs), or $null without LOCALAPPDATA. A seam for tests.
.OUTPUTS
    [string] or $null.
#>
function Get-DiagnosticsUserPhaseDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return $null
    }
    return (Join-Path $env:LOCALAPPDATA 'winget-app-setup')
}

<#
.SYNOPSIS
    Reads log files into the bundle, within what is left of its size budget.
.PARAMETER Files
    The files to read.
.PARAMETER Prefix
    The folder they go in inside the .zip, such as 'logs/'.
.PARAMETER Entries
    The bundle's entries (path inside the .zip to text): the files are added to it.
.PARAMETER Sources
    README.txt's list of sources: a file that cannot be read is noted there.
.PARAMETER BudgetBytes
    What is left of the bundle's size budget.
.OUTPUTS
    [pscustomobject] with BudgetBytes (what is left after these files) and Skipped (the names of the
    files left out because the budget was spent).
#>
function Add-DiagnosticsLogEntry {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Sources,

        [Parameter(Mandatory = $true)]
        [long]$BudgetBytes
    )

    $skipped = @()
    foreach ($file in @($Files)) {
        if ($null -eq $file) {
            continue
        }
        if ($BudgetBytes -le 0) {
            $skipped += $file.Name
            continue
        }
        try {
            $content = Read-DiagnosticsTextFile -Path $file.FullName -MaxBytes ([Math]::Min([long]4MB, $BudgetBytes))
            $BudgetBytes -= [Math]::Min([long]$file.Length, [long]4MB)
            $Entries[$Prefix + $file.Name] = $content
        }
        catch {
            $Sources.Add(('Log {0}: not read: {1}' -f $file.Name, $_.Exception.Message))
        }
    }
    return [pscustomobject]@{ BudgetBytes = $BudgetBytes; Skipped = $skipped }
}

<#
.SYNOPSIS
    Makes the diagnostics bundle (-CollectDiagnostics) and says where it is.
.DESCRIPTION
    Collects, then redacts and zips:
      README.txt                  what the bundle is, what was removed, and what each source gave
      system.txt                  Get-DiagnosticsSystemReport
      winget.txt                  Get-DiagnosticsWingetReport
      appx.txt                    Get-DiagnosticsAppxReport
      wau-updates-log-tail.txt    Get-DiagnosticsWauLogTail
      logs\                       the latest run's transcripts (the RMM wrapper's included), its
                                  installer logs and last-run.json (Select-DiagnosticsLogFile)
      user-phase\                 this account's user-phase.json and latest user phase logs, when
                                  the user phase has run here
    Every text file goes through ConvertTo-RedactedDiagnosticText with one map for the bundle. No
    environment variables are collected wholesale, and no secret is read. Read-only apart from the
    .zip, in the first folder of Get-DiagnosticsBundleDirectory that takes it. Needs neither winget
    nor administrator rights: what cannot be read is noted in README.txt.
.PARAMETER LogDirectory
    The installer's logs folder. Default %ProgramData%\winget-app-setup\logs.
.PARAMETER OutputDirectory
    The folders to try for the .zip, in order. Default: Get-DiagnosticsBundleDirectory.
.OUTPUTS
    [int] 0 when the bundle was saved, 5 when it could not be.
#>
function Invoke-DiagnosticsCollection {
    param (
        [Parameter(Mandatory = $false)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [string[]]$OutputDirectory
    )

    Write-Info 'Making a diagnostics bundle for a GitHub issue: the installer''s logs and the state of winget, App Installer and auto-updates on this PC. Nothing on this PC is changed.'
    if ([string]::IsNullOrWhiteSpace($LogDirectory) -and $env:ProgramData) {
        $LogDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    }

    $account = $null
    try {
        $account = Get-InstallAccountContext
    }
    catch {
        $account = $null
    }
    $isAdmin = [bool](Test-IsAdmin)
    $isWow64 = $false
    try {
        $isWow64 = [bool](Test-DiagnosticsWow64Process)
    }
    catch {
        $isWow64 = $false
    }

    $sources = New-Object System.Collections.Generic.List[string]
    $entries = [ordered]@{}
    $entries['README.txt'] = ''

    $budget = [long]64MB
    if ($LogDirectory -and (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        try {
            $selection = Select-DiagnosticsLogFile -LogDirectory $LogDirectory
            $files = @($selection.Transcripts) + @($selection.InstallerLogs)
            if ($selection.RunRecord) {
                $files += $selection.RunRecord
            }
            $added = Add-DiagnosticsLogEntry -Files $files -Prefix 'logs/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $added.BudgetBytes
            $sources.Add(('Installer logs ({0}): {1} transcript(s), {2} installer log(s), last-run.json {3}' -f $LogDirectory, @($selection.Transcripts).Count, @($selection.InstallerLogs).Count, $(if ($selection.RunRecord) { 'included' } else { 'not found' })))
            if (@($added.Skipped).Count -gt 0) {
                $sources.Add(('Left out to keep the bundle small: {0}' -f (@($added.Skipped) -join ', ')))
            }
            $listing = @($selection.Files | Sort-Object -Property Name | ForEach-Object { '  {0}  {1} bytes  {2}' -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) })
            if ($listing.Count -gt 0) {
                $sources.Add('Files in the logs folder:')
                foreach ($line in $listing) {
                    $sources.Add($line)
                }
            }
        }
        catch {
            $sources.Add(('Installer logs ({0}): not read: {1}' -f $LogDirectory, $_.Exception.Message))
        }
    }
    else {
        $sources.Add(('Installer logs ({0}): the folder does not exist or cannot be opened' -f $LogDirectory))
    }

    # The user phase of the account making the bundle: its state and its latest
    # attempt's transcript and winget logs, read-only like the rest.
    $userPhaseDirectory = $null
    try {
        $userPhaseDirectory = Get-DiagnosticsUserPhaseDirectory
    }
    catch {
        $userPhaseDirectory = $null
    }
    if ($userPhaseDirectory -and (Test-Path -LiteralPath $userPhaseDirectory -PathType Container)) {
        try {
            $userPhaseFiles = @()
            $statePath = Join-Path $userPhaseDirectory 'user-phase.json'
            $stateFound = Test-Path -LiteralPath $statePath -PathType Leaf
            if ($stateFound) {
                $userPhaseFiles += Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
            }
            $userLogDirectory = Join-Path $userPhaseDirectory 'logs'
            $userTranscripts = @()
            $userInstallerLogs = @()
            if (Test-Path -LiteralPath $userLogDirectory -PathType Container) {
                $userSelection = Select-DiagnosticsLogFile -LogDirectory $userLogDirectory -MaximumTranscripts 2
                $userTranscripts = @($userSelection.Transcripts)
                $userInstallerLogs = @($userSelection.InstallerLogs)
            }
            $added = Add-DiagnosticsLogEntry -Files @($userPhaseFiles) -Prefix 'user-phase/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $added.BudgetBytes
            $addedLogs = Add-DiagnosticsLogEntry -Files (@($userTranscripts) + @($userInstallerLogs)) -Prefix 'user-phase/logs/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $addedLogs.BudgetBytes
            $sources.Add(('User phase of this account ({0}): user-phase.json {1}, {2} transcript(s), {3} installer log(s)' -f $userPhaseDirectory, $(if ($stateFound) { 'included' } else { 'not found' }), $userTranscripts.Count, $userInstallerLogs.Count))
            $userSkipped = @($added.Skipped) + @($addedLogs.Skipped)
            if ($userSkipped.Count -gt 0) {
                $sources.Add(('Left out to keep the bundle small: {0}' -f ($userSkipped -join ', ')))
            }
        }
        catch {
            $sources.Add(('User phase of this account ({0}): not read: {1}' -f $userPhaseDirectory, $_.Exception.Message))
        }
    }
    else {
        $sources.Add('User phase of this account: it has not run here (no %LOCALAPPDATA%\winget-app-setup)')
    }

    try {
        $entries['system.txt'] = (@(Get-DiagnosticsSystemReport -AccountContext $account -IsAdmin $isAdmin) -join [Environment]::NewLine)
        $sources.Add('System (system.txt): collected')
    }
    catch {
        $sources.Add("System (system.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['winget.txt'] = (@(Get-DiagnosticsWingetReport -AccountContext $account) -join [Environment]::NewLine)
        $sources.Add('winget --version and --info (winget.txt): collected')
    }
    catch {
        $sources.Add("winget --version and --info (winget.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['appx.txt'] = (@(Get-DiagnosticsAppxReport) -join [Environment]::NewLine)
        $sources.Add('AppX packages (appx.txt): collected')
    }
    catch {
        $sources.Add("AppX packages (appx.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['wau-updates-log-tail.txt'] = (@(Get-DiagnosticsWauLogTail) -join [Environment]::NewLine)
        $sources.Add('Winget-AutoUpdate log (wau-updates-log-tail.txt): collected')
    }
    catch {
        $sources.Add("Winget-AutoUpdate log (wau-updates-log-tail.txt): not collected: $($_.Exception.Message)")
    }

    $buildId = 'unknown'
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $readme = @(
        'winget-app-setup diagnostics bundle',
        ('Made {0} by installer build {1}, without changing anything on the PC.' -f (Format-RunRecordTime -Time ([DateTime]::UtcNow)), $buildId),
        '',
        'Removed for the public issue: account names, the computer name, domain names, user profile folder names, the security identifiers (SIDs) of real accounts and email addresses. Each became a placeholder such as <user1>, <computer1>, <domain1> or S-1-5-21-<sid1>-1001, the same one in every file. Built-in accounts and well-known SIDs (SYSTEM, Administrators, S-1-5-18, S-1-5-32-544) were kept. Look through the files before you attach the bundle anyway.',
        '',
        'Files:',
        '  system.txt                Windows build, accounts and elevation, PowerShell and execution policy, Group Policy for App Installer and the Store, pending restart, Winget-AutoUpdate',
        '  winget.txt                winget --version and winget --info',
        '  appx.txt                  App Installer and Windows App Runtime packages, registered and provisioned',
        '  wau-updates-log-tail.txt  the end of Winget-AutoUpdate''s updates.log',
        '  logs\                     the latest run''s transcripts (the RMM wrapper''s install-<time>-rmm.log too) and installer logs, and last-run.json',
        '  user-phase\               this account''s user phase, when it has run here: user-phase.json, its latest transcripts and winget logs'
    )
    if (-not $isAdmin) {
        $readme += ''
        $readme += 'This PowerShell was not elevated, so the AppX packages of other accounts, the provisioned packages and maybe some logs could not be read. Run the command again from PowerShell started as administrator for those.'
    }
    if ($isWow64) {
        $readme += ''
        $readme += (Get-DiagnosticsWow64Note)
    }
    $readme += ''
    $readme += 'Sources:'
    foreach ($line in $sources) {
        $readme += ('  ' + $line)
    }
    $entries['README.txt'] = $readme -join [Environment]::NewLine

    $hint = $null
    try {
        $hint = Get-DiagnosticsIdentityHint -AccountContext $account
    }
    catch {
        $hint = $null
    }
    $texts = @(foreach ($name in @($entries.Keys)) { [string]$entries[$name] })
    $map = New-DiagnosticsRedactionMap -IdentityHint $hint -Text $texts
    $redacted = [ordered]@{}
    foreach ($name in @($entries.Keys)) {
        $redacted[$name] = ConvertTo-RedactedDiagnosticText -Text ([string]$entries[$name]) -Map $map
    }

    $directories = @($OutputDirectory | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($directories.Count -eq 0) {
        $directories = @(Get-DiagnosticsBundleDirectory -AccountContext $account)
    }
    $fileName = 'winget-app-setup-diagnostics-{0:yyyyMMdd-HHmmss}.zip' -f (Get-Date)
    foreach ($directory in $directories) {
        $path = Join-Path $directory $fileName
        try {
            Save-DiagnosticsBundle -Path $path -Entry $redacted
            Write-Success "Diagnostics bundle saved: $path"
            Write-Info 'Attach it to the GitHub issue: https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml. Account and computer names were removed from it; look through it before you attach it anyway.'
            if (-not $isAdmin) {
                Write-WarningMessage 'This PowerShell is not elevated, so some of the PC''s state could not be read (see README.txt in the bundle). For a complete bundle, run the same command from PowerShell started as administrator.'
            }
            if ($isWow64) {
                Write-WarningMessage (Get-DiagnosticsWow64Note)
            }
            return 0
        }
        catch {
            Write-WarningMessage ('Could not save the diagnostics bundle in {0}: {1}' -f $directory, $_.Exception.Message)
        }
    }
    Write-ErrorMessage 'The diagnostics bundle could not be saved in any folder (see above).'
    return 5
}
