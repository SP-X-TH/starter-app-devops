[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupFile,

    [string]$TargetDatabase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-DockerText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed (exit code $LASTEXITCODE)"
    }
    return ($output | Out-String).Trim()
}

function Assert-Prerequisites {
    Invoke-DockerText -Arguments @('version', '--format', '{{.Server.Version}}') | Out-Null
    Invoke-DockerText -Arguments @('compose', 'version', '--short') | Out-Null

    $containerId = Invoke-DockerText -Arguments @('compose', 'ps', '-q', 'db')
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        throw 'The db service container was not found. Start the stack before restore.'
    }

    $running = Invoke-DockerText -Arguments @('inspect', '--format', '{{.State.Running}}', $containerId)
    if ($running -ne 'true') {
        throw 'The db service is not running.'
    }
}

function Get-ContainerEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FallbackName
    )

    $value = (& docker compose exec -T db printenv $Name 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        $value = (& docker compose exec -T db printenv $FallbackName 2>$null | Out-String).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Neither $Name nor $FallbackName was found in the db service."
    }
    return $value
}

function Invoke-DockerWithFileInput {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string[]]$DockerArguments,
        [switch]$DiscardOutput
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'docker'
    $startInfo.Arguments = ($DockerArguments | ForEach-Object {
        '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"'
    }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start the Docker command.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        $inputStream = [System.IO.File]::OpenRead($InputFile)
        try {
            $inputStream.CopyTo($process.StandardInput.BaseStream)
        }
        finally {
            $inputStream.Dispose()
            $process.StandardInput.Close()
        }

        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        throw "PostgreSQL command failed (exit code $exitCode): $($stderr.Trim())"
    }

    if (-not $DiscardOutput) {
        return $stdout
    }
}

try {
    Push-Location $projectRoot
    try {
        Assert-Prerequisites

        $resolvedBackup = (Resolve-Path -LiteralPath $BackupFile -ErrorAction Stop).Path
        $backup = Get-Item -LiteralPath $resolvedBackup
        if (-not $backup.PSIsContainer -and $backup.Length -le 0) {
            throw 'The backup file is empty.'
        }
        if ($backup.PSIsContainer) {
            throw 'BackupFile must be a file, not a directory.'
        }

        $mainDatabase = Get-ContainerEnvironmentValue -Name 'PGDATABASE' -FallbackName 'POSTGRES_DB'
        $user = Get-ContainerEnvironmentValue -Name 'PGUSER' -FallbackName 'POSTGRES_USER'

        if ([string]::IsNullOrWhiteSpace($TargetDatabase)) {
            $TargetDatabase = "${mainDatabase}_restore_test"
        }
        if ($TargetDatabase -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'TargetDatabase may contain only letters, numbers, and underscores, and cannot start with a number.'
        }
        if ($TargetDatabase.Equals($mainDatabase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Restore refused: TargetDatabase matches the primary database.'
        }

        Invoke-DockerWithFileInput -InputFile $resolvedBackup -DiscardOutput -DockerArguments @(
            'compose', 'exec', '-T', 'db', 'pg_restore', '--list'
        )

        $exists = Invoke-DockerText -Arguments @(
            'compose', 'exec', '-T', 'db', 'psql',
            '--username', $user,
            '--dbname', 'postgres',
            '--tuples-only', '--no-align',
            '--command', "SELECT 1 FROM pg_database WHERE datname = '$TargetDatabase';"
        )
        if ($exists -eq '1') {
            throw "Target database '$TargetDatabase' already exists. It will not be dropped or overwritten."
        }

        Invoke-DockerText -Arguments @(
            'compose', 'exec', '-T', 'db', 'createdb',
            '--username', $user,
            '--owner', $user,
            $TargetDatabase
        ) | Out-Null

        Invoke-DockerWithFileInput -InputFile $resolvedBackup -DiscardOutput -DockerArguments @(
            'compose', 'exec', '-T', 'db', 'pg_restore',
            '--username', $user,
            '--dbname', $TargetDatabase,
            '--no-owner',
            '--no-privileges',
            '--exit-on-error'
        )

        $tableCheck = Invoke-DockerText -Arguments @(
            'compose', 'exec', '-T', 'db', 'psql',
            '--username', $user,
            '--dbname', $TargetDatabase,
            '--tuples-only', '--no-align',
            '--command', "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('activities','registrations');"
        )
        if ($tableCheck -ne '2') {
            throw 'Restore completed without both required tables: activities and registrations.'
        }

        $counts = Invoke-DockerText -Arguments @(
            'compose', 'exec', '-T', 'db', 'psql',
            '--username', $user,
            '--dbname', $TargetDatabase,
            '--tuples-only', '--no-align',
            '--field-separator', ',',
            '--command', 'SELECT (SELECT COUNT(*) FROM activities), (SELECT COUNT(*) FROM registrations);'
        )
        $values = $counts.Split(',')

        [pscustomobject]@{
            BackupFile          = $backup.FullName
            TargetDatabase      = $TargetDatabase
            ActivitiesRecords   = [int64]$values[0]
            RegistrationsRecords = [int64]$values[1]
            RestoredAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        } | Format-List
    }
    finally {
        Pop-Location
    }
}
catch {
    [Console]::Error.WriteLine("Restore failed: $($_.Exception.Message)")
    exit 1
}
