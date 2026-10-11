# FolderAB

FolderAB records files and selected Windows Registry keys before and after a change, then writes CSV reports showing what changed.

## Quick start: files

Replace `C:\Path\To\Your\Application` with the directory you want to monitor. Run the first command before your changes and the second afterward.

```powershell
$tool = '.\FolderAB.ps1'
$scan = 'C:\Path\To\Your\Application'
$reports = 'C:\AB-Reports'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -Path $scan -Output "$reports\before.csv"
# Make your changes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -Path $scan -Output "$reports\after.csv"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Compare -Before "$reports\before.csv" -After "$reports\after.csv" -Output "$reports\changes.csv"
```

The tool creates the report directory if needed. Keep reports outside the directory being scanned. Every snapshot CSV has a companion `.manifest.json` file; keep it with the CSV.

## Include Registry changes

Set `$registry` to the Registry roots you want to watch. Change `YourVendor\YourApp` to the relevant key. Keep the roots and registry view the same for both snapshots.

```powershell
$tool = '.\FolderAB.ps1'
$scan = 'C:\Path\To\Your\Application'
$reports = 'C:\AB-Reports'
$registry = 'HKLM:\Software\YourVendor\YourApp;HKCU:\Software\YourVendor\YourApp'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -Path $scan -Output "$reports\files-before.csv" -RegistryPath $registry -RegistryOutput "$reports\registry-before.csv"
# Make your changes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -Path $scan -Output "$reports\files-after.csv" -RegistryPath $registry -RegistryOutput "$reports\registry-after.csv"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Compare -Before "$reports\files-before.csv" -After "$reports\files-after.csv" -Output "$reports\file-changes.csv" -RegistryBefore "$reports\registry-before.csv" -RegistryAfter "$reports\registry-after.csv" -RegistryReport "$reports\registry-changes.csv"
```

`HKLM:` is machine-wide and `HKCU:` belongs to the account running PowerShell. Other supported hives are `HKCR:`, `HKU:`, and `HKCC:`. You can also use full hive names, such as `HKEY_LOCAL_MACHINE\Software\YourVendor\YourApp`.

FolderAB scans the selected roots and their subkeys recursively. Keep the roots narrow to reduce unrelated changes and access errors. A watched Registry root that does not exist yet is treated as empty, so its later creation can be detected.

### Registry-only snapshots

For Registry-only work, omit the file parameters:

```powershell
$tool = '.\FolderAB.ps1'
$reports = 'C:\AB-Reports'
$registry = 'HKCU:\Software\YourVendor\YourApp'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -RegistryPath $registry -RegistryOutput "$reports\registry-before.csv"
# Make your changes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -RegistryPath $registry -RegistryOutput "$reports\registry-after.csv"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Compare -RegistryBefore "$reports\registry-before.csv" -RegistryAfter "$reports\registry-after.csv" -RegistryReport "$reports\registry-changes.csv"
```

## Command reference

| Operation | Required parameters | Output |
| --- | --- | --- |
| File snapshot | `-Path`, `-Output` | File snapshot CSV and manifest. |
| Registry snapshot | `-RegistryPath`, `-RegistryOutput` | Registry snapshot CSV and manifest. |
| Combined snapshot | Both snapshot parameter sets | File and Registry snapshots. |
| File comparison | `-Before`, `-After`, `-Output` | File change report. |
| Registry comparison | `-RegistryBefore`, `-RegistryAfter`, `-RegistryReport` | Registry change report. |
| Combined comparison | Both comparison parameter sets | File and Registry reports. |

| Parameter | Meaning |
| --- | --- |
| `Snapshot` / `Compare` | Operation name. You can instead use `-Mode Snapshot` or `-Mode Compare`. |
| `-Path` | Directory to scan. Optional in Compare mode as a full-path fallback for older file snapshots. |
| `-Output` | File snapshot CSV or file comparison report. |
| `-Before`, `-After` | File snapshot inputs. |
| `-RegistryPath` | Registry root or roots. Separate roots in a string with semicolons or commas. |
| `-RegistryOutput` | Registry snapshot CSV. |
| `-RegistryView` | `Default`, `Registry32`, or `Registry64`. Defaults to `Default`, which follows PowerShell process bitness. |
| `-RegistryBefore`, `-RegistryAfter` | Registry snapshot inputs. |
| `-RegistryReport` | Registry comparison report. |
| `-AllowIncomplete` | Compare incomplete snapshots conservatively. Unmatched entries can be reported as `Unknown`. |

Specify the complete parameters for each operation you use. File and Registry operations can run separately or together. FolderAB has no default folder or Registry root. On 64-bit Windows, select `Registry32` or `Registry64` explicitly on both snapshots when you need a specific view.

## Ways to run FolderAB

Use `powershell.exe -File` to run Windows PowerShell 5.1. Use `pwsh.exe -File` for PowerShell 7 on Windows. The command and FolderAB parameters are otherwise the same.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\FolderAB.ps1' Snapshot -Path 'C:\Path\To\Your\Application' -Output 'C:\AB-Reports\before.csv'
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Tools\FolderAB.ps1' Snapshot -Path 'C:\Path\To\Your\Application' -Output 'C:\AB-Reports\before.csv'
```

The first example assumes the current directory contains the script. The second gives its full path, so it works from anywhere. Paths with spaces should be quoted. Relative scan and output paths are resolved from the current PowerShell directory.

You can use the named operation form instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\FolderAB.ps1' -Mode Snapshot -Path 'C:\Path\To\Your\Application' -Output 'C:\AB-Reports\before.csv'
```

### cmd.exe and batch files

In cmd.exe, use double quotes. This example takes a combined snapshot; the semicolon separates Registry roots.

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\FolderAB.ps1" Snapshot -Path "C:\Path\To\Your\Application" -Output "C:\AB-Reports\before.csv" -RegistryPath "HKLM:\Software\YourVendor\YourApp;HKCU:\Software\YourVendor\YourApp" -RegistryOutput "C:\AB-Reports\registry-before.csv"
echo Exit code: %ERRORLEVEL%
```

To reuse a file snapshot command, save this as `snapshot.cmd` beside `FolderAB.ps1`:

```bat
@echo off
if "%~2"=="" (
    echo Usage: snapshot.cmd "scan directory" "snapshot CSV"
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FolderAB.ps1" Snapshot -Path "%~1" -Output "%~2"
exit /b %ERRORLEVEL%
```

```bat
snapshot.cmd "C:\Path\To\Your\Application" "C:\AB-Reports\before.csv"
snapshot.cmd "C:\Path\To\Your\Application" "C:\AB-Reports\after.csv"
```

Run Compare with the resulting `before.csv` and `after.csv` as shown in the quick start.

### PowerShell scripts and automation

Run FolderAB as a child PowerShell process when using it inside a larger script. This preserves your current session and lets you check its exit code:

```powershell
$tool = 'C:\Tools\FolderAB.ps1'
$scan = 'C:\Path\To\Your\Application'
$reports = 'C:\AB-Reports'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool Snapshot -Path $scan -Output "$reports\before.csv"
switch ($LASTEXITCODE) {
    0 { 'Snapshot complete.' }
    2 { 'Snapshot incomplete. Review before.csv.manifest.json.' }
    default { throw "Snapshot failed with exit code $LASTEXITCODE." }
}
```

For a log, create the log directory first, then redirect the child process output:

```powershell
New-Item -ItemType Directory -Path 'C:\AB-Reports' -Force | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Tools\FolderAB.ps1' Snapshot -Path 'C:\Path\To\Your\Application' -Output 'C:\AB-Reports\before.csv' *> 'C:\AB-Reports\before.log'
$code = $LASTEXITCODE
```

Task Scheduler can run the same `powershell.exe -File ... Snapshot ...` command. Choose the same Windows account for both captures, especially when watching `HKCU:`. Use distinct output filenames for before and after.

### SSH to a Windows computer

Copy FolderAB to the Windows computer and run it there. Replace the username and host with your own:

```sh
scp ./FolderAB.ps1 WINUSER@WINDOWS_HOST:FolderAB.ps1
ssh WINUSER@WINDOWS_HOST 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\WINUSER\FolderAB.ps1 Snapshot -Path "C:\Path\To\Your\Application" -Output "C:\AB-Reports\before.csv"'
```

Run another snapshot after your changes with a different output filename, then compare them. Or connect with `ssh WINUSER@WINDOWS_HOST`, start `powershell.exe -NoProfile`, and enter the PowerShell commands above. SSH is provided by your environment; FolderAB does not configure SSH.

## Reports, validation, and exit codes

File snapshots contain `RelativePath`, `FullPath`, `SizeBytes`, `LastWriteTimeUtc`, and `MD5`. File reports show the change type, full path, before and after hashes, and sizes. Files match by relative path, so a rename appears as a removal plus an addition. A timestamp-only change does not count as a content change.

Registry snapshots record keys and values. Reports include the Registry path, value name, data type, and before and after data. Binary values are Base64 encoded. The default value has an empty `ValueName` in the CSV and displays as `(Default)` in the console.

The console prints counts and up to 100 changed entries per report. The CSV contains every change. For example:

```powershell
Import-Csv 'C:\AB-Reports\changes.csv' | Where-Object Change -eq 'Added' | Format-List
Import-Csv 'C:\AB-Reports\changes.csv' | ForEach-Object { "$($_.Change): $($_.FullPath)" }
Import-Csv 'C:\AB-Reports\registry-changes.csv' | Group-Object Change | Select-Object Name, Count
```

Each snapshot manifest records the computer, user, scan scope, Registry view, time, errors, row count, and a SHA256 checksum of its CSV. Compare checks manifests and rejects mismatched scopes or altered CSVs. The checksum detects accidental edits; it is not a signature. Empty snapshots still include column headers.

A scan with access errors exits `2` and saves error details in its manifest. Compare rejects incomplete snapshots unless you pass `-AllowIncomplete`. When a snapshot may have missed entries, unmatched changes are marked `Unknown`; the comparison exits `2` to show the results are incomplete. Older CSV pairs without manifests can be compared with a warning. Do not mix an old snapshot without a manifest with a new one. Invalid columns, hashes, sizes, duplicate entries, or malformed CSV are rejected. Outputs cannot overwrite comparison inputs. Snapshot outputs must be outside the scanned directory.

Exit codes: `0` means complete, `1` means invalid input or another failure, and `2` means the snapshot or comparison is incomplete. In PowerShell, check `$LASTEXITCODE`. In cmd.exe, check `%ERRORLEVEL%`.

## Common path examples

```powershell
# Another drive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FolderAB.ps1 Snapshot -Path 'D:\Data' -Output 'C:\AB-Reports\before.csv'
# A drive root. Save output on a different drive.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FolderAB.ps1 Snapshot -Path 'C:\' -Output 'D:\AB-Reports\before.csv'
# A UNC share
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FolderAB.ps1 Snapshot -Path '\\server\share' -Output 'C:\AB-Reports\share-before.csv'
# Older file snapshots without FullPath columns
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FolderAB.ps1 Compare -Path 'C:\Path\To\Your\Application' -Before '.\old-before.csv' -After '.\old-after.csv' -Output '.\old-changes.csv'
```

FolderAB includes hidden and system files. It skips symbolic links and junctions. A scan is not atomic if files are actively changing; a file that changes during hashing is recorded as an error. MD5 is for ordinary change detection, not proof of authenticity. Registry security permissions are not compared.

## Regression checks

On Windows, from the project directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Windows-E2E.ps1
# Optionally test another installed copy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Windows-E2E.ps1 -Tool 'C:\Tools\FolderAB.ps1'
```

The checks create temporary files and an HKCU test key, exercise file and Registry changes and validation errors, compare 60,000 synthetic rows, then clean up. They passed on Windows PowerShell 5.1; the synthetic comparison peaked at about 214 MiB of working memory.

## Keep or delete snapshots

Archive each snapshot CSV with its manifest. Delete only the files you no longer need:

```powershell
Copy-Item 'C:\AB-Reports\before.csv','C:\AB-Reports\before.csv.manifest.json' 'D:\Archive\Case01'
Remove-Item 'C:\AB-Reports\before.csv','C:\AB-Reports\before.csv.manifest.json'
```

Comparison reports do not have manifests. FolderAB has no automatic archive or retention feature.
