[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$backupDirectory = Join-Path $projectRoot 'backups'

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
        throw 'The db service container was not found. Start the stack before backup.'
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

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

try {
    Push-Location $projectRoot
    try {
        Assert-Prerequisites

        $database = Get-ContainerEnvironmentValue -Name 'PGDATABASE' -FallbackName 'POSTGRES_DB'
        $user = Get-ContainerEnvironmentValue -Name 'PGUSER' -FallbackName 'POSTGRES_USER'

        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupFile = Join-Path $backupDirectory "psu_activities_$timestamp.dump"

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'docker'
        $startInfo.Arguments = @(
            'compose', 'exec', '-T', 'db', 'pg_dump',
            '--format=custom',
            '--username', (Quote-ProcessArgument $user),
            '--dbname', (Quote-ProcessArgument $database)
        ) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Unable to start pg_dump.'
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        try {
            $fileStream = [System.IO.File]::Create($backupFile)
            try {
                $process.StandardOutput.BaseStream.CopyTo($fileStream)
            }
            finally {
                $fileStream.Dispose()
            }
            $process.WaitForExit()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $exitCode = $process.ExitCode
        }
        finally {
            $process.Dispose()
        }

        if ($exitCode -ne 0) {
            if (Test-Path -LiteralPath $backupFile) {
                Remove-Item -LiteralPath $backupFile -Force
            }
            throw "pg_dump failed (exit code $exitCode): $($stderr.Trim())"
        }

        $backup = Get-Item -LiteralPath $backupFile
        if ($backup.Length -le 0) {
            Remove-Item -LiteralPath $backupFile -Force
            throw 'The backup file is empty.'
        }

        [pscustomobject]@{
            Path       = $backup.FullName
            FileName   = $backup.Name
            SizeBytes  = $backup.Length
            BackupTime = $backup.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss zzz')
        } | Format-List
    }
    finally {
        Pop-Location
    }
}
catch {
    [Console]::Error.WriteLine("Backup failed: $($_.Exception.Message)")
    exit 1
}
