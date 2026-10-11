param([string]$Tool=(Join-Path (Split-Path $PSScriptRoot -Parent) 'FolderAB.ps1'))
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$id='FolderAB-E2E-'+[Guid]::NewGuid().ToString('N')
$work=Join-Path $env:TEMP $id
$data=Join-Path $work 'data'
$key='HKCU:\Software\'+$id
$passed=0
function Check($condition,$message) { if (-not $condition) {throw "FAIL: $message"}; $script:passed++; Write-Host "PASS: $message" }
function Run([string[]]$Arguments,[int]$Expected=0) {
    $ErrorActionPreference="Continue"
    $log=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool @Arguments 2>&1
    $code=$LASTEXITCODE
    if ($code -ne $Expected) { $log | Out-Host; throw "Expected exit $Expected, got $code for $Arguments" }
}
try {
 New-Item -ItemType Directory $data -Force | Out-Null
 New-Item -ItemType Directory (Join-Path $data 'sub') | Out-Null
 'old' | Set-Content (Join-Path $data 'sub\changed.txt')
 'removed' | Set-Content (Join-Path $data 'removed.txt')
 'same' | Set-Content (Join-Path $data 'same.txt')
 New-Item $key -Force | Out-Null
 New-ItemProperty $key -Name 'Changed' -Value 'old' -PropertyType String | Out-Null
 New-ItemProperty $key -Name 'Removed' -Value 42 -PropertyType DWord | Out-Null
 New-ItemProperty $key -Name 'Binary' -Value ([byte[]](0,1,255)) -PropertyType Binary | Out-Null
 New-ItemProperty $key -Name 'Multi' -Value @('one','two') -PropertyType MultiString | Out-Null
 Set-Item $key -Value "quoted `" comma, newline`nvalue"
 $bf=Join-Path $work 'before.csv'; $af=Join-Path $work 'after.csv'
 $br=Join-Path $work 'reg-before.csv'; $ar=Join-Path $work 'reg-after.csv'
 $fr=Join-Path $work 'file-report.csv'; $rr=Join-Path $work 'reg-report.csv'
 Run @('Snapshot','-Path',$data,'-Output',$bf,'-RegistryPath',$key,'-RegistryOutput',$br)
 'new' | Set-Content (Join-Path $data 'sub\changed.txt')
 Remove-Item (Join-Path $data 'removed.txt')
 'added' | Set-Content (Join-Path $data 'sub\added.txt')
 Set-ItemProperty $key Changed 'OLD'
 Remove-ItemProperty $key Removed
 New-ItemProperty $key -Name Added -Value 'yes' -PropertyType String | Out-Null
 Run @('Snapshot','-Path',$data,'-Output',$af,'-RegistryPath',$key,'-RegistryOutput',$ar)
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$fr,'-RegistryBefore',$br,'-RegistryAfter',$ar,'-RegistryReport',$rr)
 $f=@(Import-Csv $fr); $r=@(Import-Csv $rr)
 Check ($f.Count -eq 3 -and @($f | Where-Object Change -eq 'Added').Count -eq 1 -and @($f | Where-Object Change -eq 'Removed').Count -eq 1 -and @($f | Where-Object Change -eq 'Modified').Count -eq 1) 'file added/removed/modified'
 Check (@($f | Where-Object {$_.FullPath -notlike "$data\*"}).Count -eq 0) 'full file paths'
 Check ($r.Count -eq 3 -and ($r | Where-Object ValueName -eq 'Changed').Change -eq 'Modified' -and ($r | Where-Object ValueName -eq 'Added').Change -eq 'Added' -and ($r | Where-Object ValueName -eq 'Removed').Change -eq 'Removed') 'registry changes and multiline/binary/multistring stability'
 $hash=(Get-FileHash $bf).Hash
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$bf) 1
 Check ((Get-FileHash $bf).Hash -eq $hash) 'input overwrite prevented'
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$fr,'-RegistryBefore',$br,'-RegistryAfter',$ar,'-RegistryReport',$bf) 1
 Check ((Get-FileHash $bf).Hash -eq $hash) 'cross-job overwrite prevented'
 Run @('Snapshot','-Path',$data,'-Output',(Join-Path $data 'bad.csv')) 1
 Check (-not (Test-Path (Join-Path $data 'bad.csv'))) 'outputs inside scan rejected'
 $empty=Join-Path $work 'empty'; New-Item -ItemType Directory $empty | Out-Null
 $ec=Join-Path $work 'empty.csv'
 Run @('Snapshot','-Path',$empty,'-Output',$ec)
 Check ((Get-Item $ec).Length -gt 0 -and @(Import-Csv $ec).Count -eq 0) 'empty snapshot retains header'
 Run @('Compare','-Before',$ec,'-After',$ec,'-Output',$fr)
 Check (@(Import-Csv $fr).Count -eq 0) 'empty comparison'
 Push-Location $work
 try { Run @('Snapshot','-Path',$empty,'-Output','relative.csv') } finally {Pop-Location}
 Check (Test-Path (Join-Path $work 'relative.csv')) 'relative paths follow PowerShell location'
 $bad=Join-Path $work 'bad.csv'; 'RelativePath,SizeBytes','test,1' | Set-Content $bad
 Run @('Compare','-Before',$bad,'-After',$bad,'-Output',$fr) 1
 Check $true 'missing MD5 rejected'
 'RelativePath,SizeBytes,MD5','test,1,INVALID' | Set-Content $bad
 Run @('Compare','-Before',$bad,'-After',$bad,'-Output',$fr) 1
 Check $true 'invalid MD5 rejected'
 'RelativePath,SizeBytes,MD5','test,1,d41d8cd98f00b204e9800998ecf8427e','TEST,1,d41d8cd98f00b204e9800998ecf8427e' | Set-Content $bad
 Run @('Compare','-Before',$bad,'-After',$bad,'-Output',$fr) 1
 Check $true 'case-insensitive duplicates rejected'
 Set-Content $bad ''
 Run @('Compare','-Before',$bad,'-After',$bad,'-Output',$fr) 1
 Check $true 'truncated empty CSV rejected'
 Run @('Snapshot','-RegistryPath',$key,'-RegistryOutput',$ar,'-RegistryView','Registry64')
 Run @('Compare','-RegistryBefore',$ar,'-RegistryAfter',$ar,'-RegistryReport',$rr)
 Check (@(Import-Csv $rr).Count -eq 0) 'registry-only snapshot and compare'
 $missing=$key+'\Missing'
 Run @('Snapshot','-RegistryPath',$missing,'-RegistryOutput',$br)
 New-Item $missing -Force | Out-Null
 Set-Item $missing -Value 'created'
 Run @('Snapshot','-RegistryPath',$missing,'-RegistryOutput',$ar)
 Run @('Compare','-RegistryBefore',$br,'-RegistryAfter',$ar,'-RegistryReport',$rr)
 Check (@(Import-Csv $rr | Where-Object Change -eq 'Added').Count -eq 2) 'previously absent watched registry key detected'
 Run @('Snapshot','-RegistryPath',($key+';'+$key+'\Missing'),'-RegistryOutput',$ar) 1
 Check $true 'overlapping registry roots rejected'
 Run @('Snapshot','-RegistryPath',$key,'-RegistryOutput',$br,'-RegistryView','Registry32')
 Run @('Compare','-RegistryBefore',$br,'-RegistryAfter',$ar,'-RegistryReport',$rr) 1
 Check $true 'different registry views rejected'
 # Reproduce ErrorVariable behavior with actual provider ErrorRecords.
 $enumerationErrors=@()
 Get-ChildItem -LiteralPath (Join-Path $work 'does-not-exist') -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors | Out-Null
 $strings=[Collections.Generic.List[string]]::new()
 foreach ($err in $enumerationErrors) {$strings.Add($err.ToString())}
 Check ($strings.Count -gt 0) 'enumeration ErrorRecords safely converted to saved strings'
 # A held file produces a real read error with an exact saved path.
 $locked=Join-Path $data 'locked.txt'; 'locked' | Set-Content $locked
 $handle=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try {Run @('Snapshot','-Path',$data,'-Output',$af) 2} finally {$handle.Dispose()}
 $meta=Get-Content ($af+'.manifest.json') -Raw | ConvertFrom-Json
 Check (-not $meta.Complete -and ($meta.Errors -join ' ') -like "*$locked*") 'read errors persisted with full path'
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$fr) 1
 Check $true 'incomplete snapshot rejected by default'
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$fr,'-AllowIncomplete') 2
 Check ((Import-Csv $fr | Where-Object RelativePath -eq 'removed.txt').Change -eq 'Unknown') 'incomplete scan does not falsely report deletion'
 Run @('Snapshot','-Path',$empty,'-Output',$af)
 Run @('Compare','-Before',$bf,'-After',$af,'-Output',$fr) 1
 Check $true 'mismatched scopes rejected'
 Add-Content $bf 'corrupted'
 Run @('Compare','-Before',$bf,'-After',$bf,'-Output',$fr) 1
 Check $true 'manifest integrity catches changed CSV'
 # Load only helper definitions via AST to check root handling without scanning C:\.
 $ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$null,[ref]$null)
 foreach ($name in @('Full-Path','Normalize-Root')) {
   $fn=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true)
   Invoke-Expression $fn.Extent.Text
 }
 Check ((Normalize-Root 'C:\') -eq 'C:\') 'drive root remains absolute'
 Check ((Normalize-Root '\\server\share\') -eq '\\server\share\') 'UNC share root remains absolute'
 # 60,000 rows force multiple disk sort chunks; reverse ordering covers legacy CSVs.
 $largeA=Join-Path $work 'large-a.csv'; $largeB=Join-Path $work 'large-b.csv'
 $writer=[IO.StreamWriter]::new($largeA)
 try {$writer.WriteLine('RelativePath,FullPath,SizeBytes,MD5'); for($i=60000;$i -gt 0;$i--) {$writer.WriteLine("f$i,C:\fixture\f$i,1,d41d8cd98f00b204e9800998ecf8427e")}} finally {$writer.Dispose()}
 Copy-Item $largeA $largeB
 $log=Join-Path $work 'scale.log'; $err=Join-Path $work 'scale.err'
 $process=Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tool`" Compare -Before `"$largeA`" -After `"$largeB`" -Output `"$fr`"" -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
 $null=$process.Handle
 $peak=0
 while (-not $process.HasExited) {$process.Refresh(); $peak=[Math]::Max($peak,$process.PeakWorkingSet64); Start-Sleep -Milliseconds 100}
 $process.WaitForExit()
 Write-Host "SCALE exit: $($process.ExitCode); report exists: $(Test-Path $fr)"
 Get-Content $log | Out-Host
 Get-Content $err | Out-Host
 Check ($process.ExitCode -eq 0 -and @(Import-Csv $fr).Count -eq 0) '60,000-row unsorted multi-chunk compare'
 Write-Host ('SCALE peak working set: {0:N1} MiB' -f ($peak/1MB))
 Write-Host "ALL $passed CHECKS PASSED"
} finally {
 if (Test-Path $key) {Remove-Item $key -Recurse -Force}
 if (Test-Path $work) {Remove-Item $work -Recurse -Force}
 Write-Host "CLEANED: $work and $key"
}
