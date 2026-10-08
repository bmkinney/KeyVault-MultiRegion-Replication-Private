param(
    [Parameter(Mandatory = $true)]
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$outputPath = [IO.Path]::GetFullPath($OutputFile)
$stage = Join-Path ([IO.Path]::GetTempPath()) ("mrkv-package-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'function_app.py'),(Join-Path $PSScriptRoot 'replication.py'),(Join-Path $PSScriptRoot 'host.json') -Destination $stage
    $pythonPackages = Join-Path $stage '.python_packages\lib\site-packages'
    python -m pip install --quiet --only-binary=:all: --platform manylinux2014_x86_64 --platform manylinux_2_28_x86_64 --python-version 3.11 --implementation cp --abi cp311 --abi abi3 --target $pythonPackages -r (Join-Path $PSScriptRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Python dependency packaging failed.' }

    $extensionOutput = Join-Path $stage 'bin'
    $intermediate = (Join-Path $stage 'obj') + [IO.Path]::DirectorySeparatorChar
    dotnet build (Join-Path $PSScriptRoot 'extensions.csproj') --configuration Release --output $extensionOutput "-p:BaseIntermediateOutputPath=$intermediate" --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'Function extension build failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $extensionOutput 'extensions.json'))) {
        throw 'Function extension metadata was not generated.'
    }

    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputPath)) -Force | Out-Null
    python -c "import pathlib,sys,zipfile; root=pathlib.Path(sys.argv[1]); files=sorted(p for p in root.rglob('*') if p.is_file() and 'obj' not in p.relative_to(root).parts); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED); [z.write(p,p.relative_to(root).as_posix()) for p in files]; z.close()" $stage $outputPath
    if ($LASTEXITCODE -ne 0) { throw 'Function ZIP packaging failed.' }
    Write-Output "Created prebuilt Linux/Python 3.11 package: $outputPath"
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
