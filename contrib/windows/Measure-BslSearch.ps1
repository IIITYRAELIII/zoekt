[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Source,

    [Parameter(Mandatory)]
    [string] $Index,

    [Parameter(Mandatory)]
    [string] $Zoekt,

    [ValidateRange(1, 50)]
    [int] $Repetitions = 7,

    [string] $Ripgrep = 'rg'
)

$ErrorActionPreference = 'Stop'

$sourcePath = (Get-Item -LiteralPath $Source -ErrorAction Stop).FullName
$indexPath = (Get-Item -LiteralPath $Index -ErrorAction Stop).FullName
$zoektPath = (Get-Item -LiteralPath $Zoekt -ErrorAction Stop).FullName
$ripgrepPath = (Get-Command $Ripgrep -ErrorAction Stop).Source

$cases = @(
    [pscustomobject]@{
        Name = 'exact-dynamic-type'
        Zoekt = 'case:yes content:ОписаниеТипов\(\x22ДинамическийСписок\x22\)'
        Ripgrep = @(
            '--no-ignore', '-F', '-n', '--no-heading', '--color', 'never',
            '-g', '*.bsl',
            'ОписаниеТипов("ДинамическийСписок")',
            $sourcePath
        )
    },
    [pscustomobject]@{
        Name = 'all-dynamic-list'
        Zoekt = 'case:yes content:ДинамическийСписок'
        Ripgrep = @(
            '--no-ignore', '-F', '-n', '--no-heading', '--color', 'never',
            '-g', '*.bsl',
            'ДинамическийСписок',
            $sourcePath
        )
    },
    [pscustomobject]@{
        Name = 'programmatic-form-attribute'
        Zoekt = 'case:yes content:РеквизитФормы\([^;]*ОписаниеТипов\s*\(\s*\x22ДинамическийСписок\x22'
        Ripgrep = @(
            '--no-ignore', '-U', '-P', '-o', '-n', '--no-heading',
            '--color', 'never', '-g', '*.bsl',
            'РеквизитФормы\([^;]*ОписаниеТипов\s*\(\s*"ДинамическийСписок"',
            $sourcePath
        )
    }
)

function Invoke-ZoektCase {
    param([string] $Query)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lines = @(
        & $zoektPath -jsonl -index_dir $indexPath $Query
    )
    $watch.Stop()
    if ($LASTEXITCODE -ne 0) {
        throw "Zoekt failed with exit code $LASTEXITCODE."
    }

    $matches = 0
    foreach ($line in $lines) {
        if ($line) {
            $file = $line | ConvertFrom-Json
            $matches += @($file.LineMatches).Count
        }
    }

    [pscustomobject]@{
        ElapsedMs = $watch.Elapsed.TotalMilliseconds
        Matches = $matches
    }
}

function Invoke-RipgrepCase {
    param([string[]] $Arguments)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lines = @(& $ripgrepPath @Arguments)
    $watch.Stop()
    if ($LASTEXITCODE -notin @(0, 1)) {
        throw "ripgrep failed with exit code $LASTEXITCODE."
    }

    [pscustomobject]@{
        ElapsedMs = $watch.Elapsed.TotalMilliseconds
        Matches = $lines.Count
    }
}

function Get-Median {
    param([double[]] $Values)

    $sorted = @($Values | Sort-Object)
    return $sorted[[math]::Floor($sorted.Count / 2)]
}

$results = foreach ($case in $cases) {
    $null = Invoke-ZoektCase -Query $case.Zoekt
    $null = Invoke-RipgrepCase -Arguments $case.Ripgrep

    $zoektRuns = @()
    $ripgrepRuns = @()
    for ($iteration = 1; $iteration -le $Repetitions; $iteration++) {
        $zoektRuns += Invoke-ZoektCase -Query $case.Zoekt
        $ripgrepRuns += Invoke-RipgrepCase -Arguments $case.Ripgrep
    }

    $zoektMatches = $zoektRuns[-1].Matches
    $ripgrepMatches = $ripgrepRuns[-1].Matches
    if ($zoektMatches -ne $ripgrepMatches) {
        throw "$($case.Name): Zoekt returned $zoektMatches matches, ripgrep returned $ripgrepMatches."
    }

    [pscustomobject]@{
        Name = $case.Name
        Matches = $zoektMatches
        Repetitions = $Repetitions
        ZoektMedianMs = [math]::Round(
            (Get-Median -Values $zoektRuns.ElapsedMs),
            3
        )
        RipgrepMedianMs = [math]::Round(
            (Get-Median -Values $ripgrepRuns.ElapsedMs),
            3
        )
    }
}

[pscustomobject]@{
    GeneratedAt = [DateTimeOffset]::Now.ToString('o')
    SourceFiles = @(
        [IO.Directory]::EnumerateFiles(
            $sourcePath,
            '*.bsl',
            [IO.SearchOption]::AllDirectories
        )
    ).Count
    Results = @($results)
} | ConvertTo-Json -Depth 5
