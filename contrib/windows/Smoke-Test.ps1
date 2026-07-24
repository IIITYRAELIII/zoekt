[CmdletBinding()]
param(
    [string] $Go = 'go',
    [switch] $KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath(
    [IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$temporaryBase = if ($env:RUNNER_TEMP) {
    [IO.Path]::GetFullPath($env:RUNNER_TEMP)
} else {
    [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
}
$workRoot = [IO.Path]::GetFullPath(
    [IO.Path]::Combine(
        $temporaryBase,
        "zoekt-windows-smoke-$([Guid]::NewGuid().ToString('N'))"
    )
)

if (-not $workRoot.StartsWith(
    $temporaryBase.TrimEnd('\') + '\',
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to use an unexpected temporary path: $workRoot"
}

$corpus = [IO.Path]::Combine($workRoot, 'корпус')
$index = [IO.Path]::Combine($workRoot, 'index')
$bin = [IO.Path]::Combine($workRoot, 'bin')
$stdout = [IO.Path]::Combine($workRoot, 'webserver.stdout.log')
$stderr = [IO.Path]::Combine($workRoot, 'webserver.stderr.log')
$webserver = $null

try {
    [IO.Directory]::CreateDirectory($corpus) | Out-Null
    [IO.Directory]::CreateDirectory($index) | Out-Null
    [IO.Directory]::CreateDirectory($bin) | Out-Null

    $module = @'
Процедура СоздатьСписок()
    ТипСписка = Новый ОписаниеТипов("ДинамическийСписок");
    Реквизиты = Новый Массив;
    Реквизиты.Добавить(Новый РеквизитФормы("Список", ТипСписка));
КонецПроцедуры
'@
    [IO.File]::WriteAllText(
        [IO.Path]::Combine($corpus, 'ДинамическийСписок.bsl'),
        $module,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        [IO.Path]::Combine($corpus, 'ОбычныйМодуль.bsl'),
        "Процедура Выполнить()`nКонецПроцедуры`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        [IO.Path]::Combine($corpus, 'НеИндексировать.txt'),
        'МаркерИсключенногоФайла',
        [Text.UTF8Encoding]::new($false)
    )

    Push-Location $repositoryRoot
    try {
        & $Go build -o ([IO.Path]::Combine($bin, 'zoekt-index.exe')) `
            ./cmd/zoekt-index
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to build zoekt-index.'
        }
        & $Go build -o ([IO.Path]::Combine($bin, 'zoekt.exe')) ./cmd/zoekt
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to build zoekt.'
        }
        & $Go build -o ([IO.Path]::Combine($bin, 'zoekt-webserver.exe')) `
            ./cmd/zoekt-webserver
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to build zoekt-webserver.'
        }
    }
    finally {
        Pop-Location
    }

    & ([IO.Path]::Combine($bin, 'zoekt-index.exe')) `
        -disable_ctags `
        -include_ext bsl `
        -index $index `
        -name 'windows-bsl-smoke' `
        $corpus
    if ($LASTEXITCODE -ne 0) {
        throw 'zoekt-index failed.'
    }

    $searchOutput = & ([IO.Path]::Combine($bin, 'zoekt.exe')) `
        -index_dir $index `
        'case:yes content:ДинамическийСписок'
    if ($LASTEXITCODE -ne 0) {
        throw 'zoekt search failed.'
    }
    if (($searchOutput -join "`n") -notmatch 'ДинамическийСписок') {
        throw 'The Cyrillic BSL search did not return the expected match.'
    }
    if (($searchOutput -join "`n") -match [Regex]::Escape($corpus)) {
        throw 'The index exposed an absolute source path instead of a relative file name.'
    }
    $excludedOutput = & ([IO.Path]::Combine($bin, 'zoekt.exe')) `
        -index_dir $index `
        'case:yes content:МаркерИсключенногоФайла'
    if ($LASTEXITCODE -ne 0) {
        throw 'zoekt exclusion search failed.'
    }
    if (($excludedOutput -join "`n") -match 'МаркерИсключенногоФайла') {
        throw 'The extension filter indexed an excluded text file.'
    }

    $listener = [Net.Sockets.TcpListener]::new(
        [Net.IPAddress]::Loopback,
        0
    )
    $listener.Start()
    $port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    $listener.Stop()

    $webserver = Start-Process `
        -FilePath ([IO.Path]::Combine($bin, 'zoekt-webserver.exe')) `
        -ArgumentList @('-index', $index, '-listen', "127.0.0.1:$port") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru

    $baseUri = "http://127.0.0.1:$port"
    $ready = $false
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ($webserver.HasExited) {
            throw "zoekt-webserver exited with code $($webserver.ExitCode)."
        }
        try {
            $response = Invoke-WebRequest `
                -Uri "$baseUri/healthz" `
                -UseBasicParsing `
                -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) {
        throw 'zoekt-webserver did not become ready.'
    }

    $query = [Uri]::EscapeDataString('case:yes content:ДинамическийСписок')
    $page = Invoke-WebRequest `
        -Uri "$baseUri/search?q=$query" `
        -UseBasicParsing `
        -TimeoutSec 10
    if ($page.Content -notmatch 'ДинамическийСписок') {
        throw 'The webserver did not return the expected BSL match.'
    }

    $updatedModule = $module + "`n// МаркерПереиндексации`n"
    [IO.File]::WriteAllText(
        [IO.Path]::Combine($corpus, 'ДинамическийСписок.bsl'),
        $updatedModule,
        [Text.UTF8Encoding]::new($false)
    )
    & ([IO.Path]::Combine($bin, 'zoekt-index.exe')) `
        -disable_ctags `
        -include_ext bsl `
        -index $index `
        -name 'windows-bsl-smoke' `
        $corpus
    if ($LASTEXITCODE -ne 0) {
        throw 'Live reindexing failed while zoekt-webserver was running.'
    }

    $updated = $false
    $updatedQuery = [Uri]::EscapeDataString(
        'case:yes content:МаркерПереиндексации'
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $updatedPage = Invoke-WebRequest `
            -Uri "$baseUri/search?q=$updatedQuery" `
            -UseBasicParsing `
            -TimeoutSec 10
        if ($updatedPage.Content -match 'МаркерПереиндексации') {
            $updated = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $updated) {
        throw 'The webserver did not observe the rebuilt index.'
    }

    [pscustomobject]@{
        Status = 'ok'
        Platform = [Environment]::OSVersion.VersionString
        Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        Search = 'ДинамическийСписок'
        RepositoryName = 'windows-bsl-smoke'
        ExtensionFilter = 'ok'
        Webserver = 'ok'
        LiveReindex = 'ok'
    } | ConvertTo-Json
}
finally {
    if ($webserver -and -not $webserver.HasExited) {
        Stop-Process -Id $webserver.Id -Force -ErrorAction SilentlyContinue
        $webserver.WaitForExit()
    }
    if (-not $KeepArtifacts -and [IO.Directory]::Exists($workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
