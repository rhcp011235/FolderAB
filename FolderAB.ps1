[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('Snapshot','Compare')][string]$Mode,
    [string]$Path, [string]$Output, [string]$Before, [string]$After,
    [string[]]$RegistryPath, [string]$RegistryOutput,
    [string]$RegistryBefore, [string]$RegistryAfter, [string]$RegistryReport,
    [ValidateSet('Default','Registry32','Registry64')][string]$RegistryView='Default',
    [switch]$AllowIncomplete
)
$ErrorActionPreference='Stop'
# A streaming CSV reader and disk merge sort keep large registry comparisons bounded.
if (-not ('FolderAB.Core' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace FolderAB {
 public sealed class Csv : IDisposable {
  StreamReader reader;
  public Csv(string path) { reader=new StreamReader(path,Encoding.UTF8,true); }
  public string[] Read() {
   var fields=new List<string>(); var s=new StringBuilder(); bool quoted=false,closed=false,start=true,any=false;
   while(true) {
    int n=reader.Read();
    if(n<0) { if(quoted) throw new InvalidDataException("Unterminated CSV quote"); if(!any) return null; fields.Add(s.ToString()); return fields.ToArray(); }
    any=true; char c=(char)n;
    if(quoted) { if(c=='"') { if(reader.Peek()=='"') { reader.Read(); s.Append('"'); } else { quoted=false; closed=true; } } else s.Append(c); continue; }
    if(c==',' || c=='\r' || c=='\n') {
     fields.Add(s.ToString()); s.Length=0; start=true; closed=false;
     if(c!=',') { if(c=='\r' && reader.Peek()=='\n') reader.Read(); return fields.ToArray(); } continue;
    }
    if(closed) throw new InvalidDataException("Unexpected text after CSV quote");
    if(c=='"') { if(!start) throw new InvalidDataException("Quote inside unquoted CSV field"); quoted=true; start=false; }
    else { s.Append(c); start=false; }
   }
  }
  public void Dispose() { reader.Dispose(); }
 }
 public sealed class Sink : IDisposable {
  StreamWriter writer;
  public long Count {get;private set;}
  public Sink(string path,string[] header) { writer=new StreamWriter(path,false,new UTF8Encoding(true)); Write(header); Count=0; }
  public void Write(string[] fields) {
   for(int i=0;i<fields.Length;i++) { if(i>0) writer.Write(','); writer.Write('"'); writer.Write((fields[i]??"").Replace("\"","\"\"")); writer.Write('"'); }
   writer.WriteLine(); Count++;
  }
  public void Dispose() { writer.Dispose(); }
 }
 public sealed class Record { public string Key; public string[] Row; }
 public sealed class Records : IDisposable {
  BinaryReader reader;
  public Records(string path) { reader=new BinaryReader(File.OpenRead(path),Encoding.UTF8); }
  public Record Read() {
   if(reader.BaseStream.Position==reader.BaseStream.Length) return null;
   string key=reader.ReadString(); int n=reader.ReadInt32(); var row=new string[n];
   for(int i=0;i<n;i++) row[i]=reader.ReadString(); return new Record {Key=key,Row=row};
  }
  public void Dispose() {reader.Dispose();}
 }
 public sealed class Cursor : IDisposable {
  IEnumerator<string[]> iterator;
  public Cursor(IEnumerable<string[]> rows) {iterator=rows.GetEnumerator();}
  public bool MoveNext() {return iterator.MoveNext();}
  public string[] Current {get {return iterator.Current;}}
  public void Dispose() {iterator.Dispose();}
 }
 public static class Core {
  public static Cursor OpenCompare(string before,string after,bool registry,bool oldIncomplete,bool newIncomplete,string root) {return new Cursor(Compare(before,after,registry,oldIncomplete,newIncomplete,root));}
  public static long LastRowCount {get;private set;}
  static StringComparer cmp=StringComparer.OrdinalIgnoreCase;
  static void Write(BinaryWriter w,Record r) { w.Write(r.Key); w.Write(r.Row.Length); foreach(string s in r.Row) w.Write(s); }
  static string Temp(string dir) { return System.IO.Path.Combine(dir,Guid.NewGuid().ToString("N")); }
  static string Merge(List<string> paths,string dir) {
   string dest=Temp(dir); var readers=new List<Records>(); var heads=new List<Record>();
   try {
    foreach(string p in paths) { var r=new Records(p); readers.Add(r); heads.Add(r.Read()); }
    using(var w=new BinaryWriter(File.Create(dest),Encoding.UTF8)) {
     while(true) { int best=-1; for(int i=0;i<heads.Count;i++) if(heads[i]!=null && (best<0 || cmp.Compare(heads[i].Key,heads[best].Key)<0)) best=i;
      if(best<0) break; Write(w,heads[best]); heads[best]=readers[best].Read(); }
    }
   } finally { foreach(var r in readers) r.Dispose(); }
   foreach(string p in paths) File.Delete(p); return dest;
  }
  public static string Sort(string source,bool registry,string dir) {
   var chunks=new List<string>(); var rows=new List<Record>(); long bytes=0;
   using(var csv=new Csv(source)) {
    string[] h=csv.Read(); if(h==null) throw new InvalidDataException("Empty CSV has no header: "+source);
    var columns=new Dictionary<string,int>(cmp);
    for(int i=0;i<h.Length;i++) { if(columns.ContainsKey(h[i])) throw new InvalidDataException("Duplicate CSV column"); columns.Add(h[i],i); }
    string[] required=registry?new[]{"EntryType","RegistryPath","ValueName","ValueKind","DataJson"}:new[]{"RelativePath","SizeBytes","MD5"};
    foreach(string c in required) if(!columns.ContainsKey(c)) throw new InvalidDataException("Missing CSV column "+c+": "+source);
    string[] row;
    while((row=csv.Read())!=null) {
     if(row.Length!=h.Length) throw new InvalidDataException("Wrong CSV field count: "+source);
     string[] canonical;
     string key;
     if(registry) {
      canonical=new string[5]; for(int i=0;i<5;i++) canonical[i]=row[columns[required[i]]];
      if((canonical[0]!="Key" && canonical[0]!="Value") || canonical[1].Length==0 || canonical[1].IndexOf('\0')>=0 || canonical[2].IndexOf('\0')>=0) throw new InvalidDataException("Invalid registry identity");
      if(canonical[0]=="Key" && (canonical[2]!="" || canonical[3]!="" || canonical[4]!="")) throw new InvalidDataException("Invalid registry key row");
      if(canonical[0]=="Value" && Array.IndexOf(new[]{"String","ExpandString","Binary","DWord","MultiString","QWord","None"},canonical[3])<0) throw new InvalidDataException("Invalid registry value kind");
      key=canonical[1]+"\0"+canonical[0]+"\0"+canonical[2];
     } else {
      string relative=row[columns["RelativePath"]]; long size;
      string md5=row[columns["MD5"]];
      if(relative.Length==0 || relative.IndexOf('\0')>=0 || System.IO.Path.IsPathRooted(relative) || Array.IndexOf(relative.Replace('\\','/').Split('/'),"..")>=0 || !long.TryParse(row[columns["SizeBytes"]],out size) || size<0 || !System.Text.RegularExpressions.Regex.IsMatch(md5,"\\A[0-9a-fA-F]{32}\\z")) throw new InvalidDataException("Invalid file snapshot row: "+relative);
      canonical=new[]{relative,columns.ContainsKey("FullPath")?row[columns["FullPath"]]:"",row[columns["SizeBytes"]],md5}; key=relative;
     }
     rows.Add(new Record{Key=key,Row=canonical}); foreach(string s in canonical) bytes+=2L*s.Length+64;
     if(bytes>=16*1024*1024 || rows.Count>=25000) { chunks.Add(Chunk(rows,dir)); rows.Clear(); bytes=0; }
    }
   }
   if(rows.Count>0 || chunks.Count==0) chunks.Add(Chunk(rows,dir));
   while(chunks.Count>1) { var next=new List<string>(); for(int i=0;i<chunks.Count;i+=32) next.Add(Merge(chunks.GetRange(i,Math.Min(32,chunks.Count-i)),dir)); chunks=next; }
   LastRowCount=0;
   using(var reader=new Records(chunks[0])) { Record r; string last=null; while((r=reader.Read())!=null) { if(last!=null && cmp.Equals(last,r.Key)) throw new InvalidDataException("Duplicate snapshot identity: "+r.Key.Replace('\0',' ')); last=r.Key; LastRowCount++; } }
   return chunks[0];
  }
  static string Chunk(List<Record> rows,string dir) { rows.Sort((a,b)=>cmp.Compare(a.Key,b.Key)); string p=Temp(dir); using(var w=new BinaryWriter(File.Create(p),Encoding.UTF8)) foreach(var r in rows) Write(w,r); return p; }
  public static IEnumerable<string[]> Compare(string before,string after,bool registry,bool oldIncomplete,bool newIncomplete,string root) {
   using(var a=new Records(before)) using(var b=new Records(after)) {
    Record x=a.Read(),y=b.Read();
    while(x!=null || y!=null) {
     int c=x==null?1:y==null?-1:cmp.Compare(x.Key,y.Key); string change=null; string[] old=null,now=null;
     if(c<0) { old=x.Row; change=newIncomplete?"Unknown":"Removed"; x=a.Read(); }
     else if(c>0) { now=y.Row; change=oldIncomplete?"Unknown":"Added"; y=b.Read(); }
     else { old=x.Row; now=y.Row; if(registry?(old[3]!=now[3] || old[4]!=now[4]):!cmp.Equals(old[3],now[3])) change="Modified"; x=a.Read(); y=b.Read(); }
     if(change==null) continue; var e=now??old;
     if(registry) yield return new[]{change,e[0],e[1],e[2],old==null?"":old[3],now==null?"":now[3],old==null?"":old[4],now==null?"":now[4]};
     else yield return new[]{change,e[1]!=""?e[1]:root!=""?System.IO.Path.Combine(root,e[0]):e[0],e[0],old==null?"":old[3],now==null?"":now[3],old==null?"":old[2],now==null?"":now[2]};
    }
   }
  }
 }
}
'@
}
function Full-Path([string]$Value) {
    $provider=$null; $drive=$null
    $result=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value,[ref]$provider,[ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "A filesystem path is required: $Value" }
    return $result
}
function Normalize-Root([string]$Value) {
    $full=Full-Path $Value
    $base=[IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\','/') -eq $base.TrimEnd('\','/')) { return $base.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar }
    return $full.TrimEnd('\','/')
}
function Publish-File([string]$Source,[string]$Destination) {
    $parent=[IO.Path]::GetDirectoryName($Destination)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $stage=Join-Path $parent ('.FolderAB-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::Copy($Source,$stage,$false)
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($stage,$Destination,[NullString]::Value) }
        else { [IO.File]::Move($stage,$Destination) }
    } finally { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
}
function Save-Manifest($Job,$Errors,$Started,$Count) {
    $metadata=[ordered]@{ Version=2; Kind=$Job.Kind; Computer=[Environment]::MachineName;
        User=[Environment]::UserDomainName+'\'+[Environment]::UserName; Scope=$Job.Scope;
        RegistryView=$Job.View; StartedUtc=$Started; FinishedUtc=[DateTime]::UtcNow.ToString('o');
        Complete=($Errors.Count -eq 0); Errors=@($Errors.ToArray()); RowCount=$Count;
        LinkPolicy='Skip reparse points'; SHA256=(Get-FileHash -LiteralPath $Job.Temp -Algorithm SHA256).Hash }
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ($Job.Temp+'.manifest.json') -Encoding UTF8
}
function Read-Manifest($Job,[string]$InputPath) {
    $sidecar=$InputPath+'.manifest.json'
    if (-not (Test-Path -LiteralPath $sidecar)) { Write-Warning "Legacy CSV: scope and completeness cannot be verified: $InputPath"; return $null }
    $m=Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
    if ($m.Version -ne 2 -or $m.Kind -ne $Job.Kind -or $m.Complete -isnot [bool] -or @($m.Scope).Count -eq 0 -or $m.RowCount -isnot [ValueType] -or $m.RowCount -lt 0 -or -not $m.Computer -or -not $m.User -or $m.SHA256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Invalid manifest: $sidecar" }
    if ((Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash -ne $m.SHA256) { throw "Snapshot integrity check failed: $InputPath" }
    if (-not $m.Complete -and -not $AllowIncomplete) { throw "Snapshot is incomplete: $InputPath. Review its manifest, or use -AllowIncomplete for a conservative comparison." }
    return $m
}
function Get-RegistryPathParts([string] $Value) {
    $normalized = $Value.Trim().Replace('/', '\')
    $parts = $normalized -split '\\', 2
    $hiveToken = $parts[0].TrimEnd(':').ToUpperInvariant()
    switch ($hiveToken) {
        { $_ -in @('HKLM', 'HKEY_LOCAL_MACHINE') } { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine; $hiveName = 'HKEY_LOCAL_MACHINE'; break }
        { $_ -in @('HKCU', 'HKEY_CURRENT_USER') } { $hive = [Microsoft.Win32.RegistryHive]::CurrentUser; $hiveName = 'HKEY_CURRENT_USER'; break }
        { $_ -in @('HKCR', 'HKEY_CLASSES_ROOT') } { $hive = [Microsoft.Win32.RegistryHive]::ClassesRoot; $hiveName = 'HKEY_CLASSES_ROOT'; break }
        { $_ -in @('HKU', 'HKEY_USERS') } { $hive = [Microsoft.Win32.RegistryHive]::Users; $hiveName = 'HKEY_USERS'; break }
        { $_ -in @('HKCC', 'HKEY_CURRENT_CONFIG') } { $hive = [Microsoft.Win32.RegistryHive]::CurrentConfig; $hiveName = 'HKEY_CURRENT_CONFIG'; break }
        default { throw "Unsupported registry hive in '$Value'. Use HKLM:, HKCU:, HKCR:, HKU:, or HKCC:." }
    }
    $subKey = if ($parts.Count -gt 1) { $parts[1].Trim('\') } else { '' }
    $canonicalPath = if ([string]::IsNullOrEmpty($subKey)) { $hiveName } else { "$hiveName\$subKey" }
    return [pscustomobject]@{ Hive = $hive; HiveName = $hiveName; SubKey = $subKey; CanonicalPath = $canonicalPath }
}


function Write-RegistryTree($Key,[string]$KeyPath,$Sink,$Errors) {
    $Sink.Write([string[]]@('Key',$KeyPath,'','',''))
    try {
        foreach ($name in $Key.GetValueNames()) {
            try {
                $kind=$Key.GetValueKind($name).ToString()
                $value=$Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $value) { throw 'Value disappeared while scanning.' }
                $data=if ($kind -in @('Binary','None')) { [Convert]::ToBase64String([byte[]]$value) } else { ConvertTo-Json -InputObject $value -Depth 10 -Compress }
                $Sink.Write([string[]]@('Value',$KeyPath,$name,$kind,[string]$data))
            } catch { $Errors.Add("$KeyPath [$name]: $($_.Exception.Message)") }
        }
        if ($Sink.Count % 1000 -lt 20) { Write-Progress -Activity 'Registry snapshot' -Status "$($Sink.Count) entries; $KeyPath" }
        foreach ($child in $Key.GetSubKeyNames()) {
            $sub=$null
            try {
                $sub=$Key.OpenSubKey($child,$false)
                if ($null -eq $sub) { throw 'Key disappeared or could not be read.' }
                Write-RegistryTree $sub "$KeyPath\$child" $Sink $Errors
            } catch { $Errors.Add("$KeyPath\$child`: $($_.Exception.Message)") }
            finally { if ($null -ne $sub) { $sub.Dispose() } }
        }
    } catch { $Errors.Add("$KeyPath`: $($_.Exception.Message)") }
}
$jobs=@(); $work=$null; $incomplete=$false
try {
    if ($Mode -eq 'Snapshot') {
        if ($Path -or $Output) {
            if (-not $Path -or -not $Output) { throw 'File snapshot requires -Path and -Output.' }
            $root=Normalize-Root $Path
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Folder does not exist: $root" }
            $jobs+=@{Kind='Files';Dest=(Full-Path $Output);Scope=@($root);View=''}
        }
        if ($RegistryPath -or $RegistryOutput) {
            if (-not $RegistryPath -or -not $RegistryOutput) { throw 'Registry snapshot requires -RegistryPath and -RegistryOutput.' }
            $roots=@($RegistryPath | ForEach-Object { $_ -split '[;,]' } | Where-Object { $_.Trim() } | ForEach-Object { Get-RegistryPathParts $_ })
            if ($roots.Count -eq 0) { throw 'Supply at least one registry root.' }
            $roots=@($roots | Sort-Object CanonicalPath -Unique)
            for($i=0;$i -lt $roots.Count;$i++) { for($j=0;$j -lt $i;$j++) { if ($roots[$i].CanonicalPath.StartsWith($roots[$j].CanonicalPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Registry roots must not overlap.' } } }
            $view=if ($RegistryView -eq 'Default') { if ([Environment]::Is64BitProcess) {'Registry64'} else {'Registry32'} } else {$RegistryView}
            $jobs+=@{Kind='Registry';Dest=(Full-Path $RegistryOutput);Scope=@($roots.CanonicalPath);View=$view}
        }
    } else {
        if ($Before -or $After -or $Output) {
            if (-not $Before -or -not $After -or -not $Output) { throw 'File compare requires -Before, -After and -Output.' }
            $jobs+=@{Kind='Files';Dest=(Full-Path $Output);Before=(Full-Path $Before);After=(Full-Path $After)}
        }
        if ($RegistryBefore -or $RegistryAfter -or $RegistryReport) {
            if (-not $RegistryBefore -or -not $RegistryAfter -or -not $RegistryReport) { throw 'Registry compare requires -RegistryBefore, -RegistryAfter and -RegistryReport.' }
            $jobs+=@{Kind='Registry';Dest=(Full-Path $RegistryReport);Before=(Full-Path $RegistryBefore);After=(Full-Path $RegistryAfter)}
        }
    }
    if ($jobs.Count -eq 0) { throw 'Specify a file job, a registry job, or both. See README.md.' }
    # Validate every destination before opening any output.
    $reserved=@((Full-Path $PSCommandPath)); $destinations=@()
    foreach ($job in $jobs) {
        if ($Mode -eq 'Compare') { foreach ($inputFile in @($job.Before,$job.After)) { $reserved+=@($inputFile,$inputFile+'.manifest.json') } }
        $destinations+=$job.Dest
        if ($Mode -eq 'Snapshot') { $destinations+=($job.Dest+'.manifest.json') }
    }
    $seen=@{}
    foreach ($dest in $destinations) {
        if ($seen.ContainsKey($dest) -or $reserved -contains $dest) { throw "Output path collides with an input or another output: $dest" }
        $seen[$dest]=$true
        if ($Mode -eq 'Snapshot' -and $root -and ($dest -ieq $root -or $dest.StartsWith($root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) { throw 'Save outputs outside the scanned folder.' }
    }
    $work=Join-Path ([IO.Path]::GetTempPath()) ('FolderAB-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    foreach ($job in $jobs) { $job.Temp=Join-Path $work ([Guid]::NewGuid().ToString('N')+'.csv') }
    foreach ($job in $jobs) {
        if ($Mode -eq 'Snapshot') {
            $errors=[Collections.Generic.List[string]]::new(); $started=[DateTime]::UtcNow.ToString('o')
            $header=if ($job.Kind -eq 'Files') { @('RelativePath','FullPath','SizeBytes','LastWriteTimeUtc','MD5') } else { @('EntryType','RegistryPath','ValueName','ValueKind','DataJson') }
            $sink=[FolderAB.Sink]::new($job.Temp,[string[]]$header)
            try {
                if ($job.Kind -eq 'Files') {
                    $stack=[Collections.Generic.Stack[string]]::new(); $stack.Push($root)
                    while ($stack.Count) {
                        $dir=$stack.Pop(); $enumerationErrors=@()
                        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors | ForEach-Object {
                            $file=$_; $fileName=$file.FullName
                            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
                            if ($file.PSIsContainer) { $stack.Push($fileName); return }
                            try {
                                $length=$file.Length; $stamp=$file.LastWriteTimeUtc
                                $hash=(Get-FileHash -LiteralPath $fileName -Algorithm MD5).Hash
                                $file.Refresh()
                                if (-not $file.Exists -or $file.Length -ne $length -or $file.LastWriteTimeUtc -ne $stamp) { throw 'File changed during hashing; take a new snapshot.' }
                                $sink.Write([string[]]@($fileName.Substring($root.Length).TrimStart('\','/'),$fileName,[string]$length,$stamp.ToString('o'),$hash))
                                if ($sink.Count % 100 -eq 0) { Write-Progress -Activity 'File snapshot' -Status "$($sink.Count) files; $fileName" }
                            } catch { $errors.Add("$fileName`: $($_.Exception.Message)") }
                        }
                        foreach ($err in $enumerationErrors) { $errors.Add("$dir`: $($err.ToString())") }
                    }
                } else {
                    foreach ($parts in $roots) {
                        $base=$null; $key=$null
                        try {
                            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($parts.Hive,[Microsoft.Win32.RegistryView]::$view)
                            $key=if ($parts.SubKey) {$base.OpenSubKey($parts.SubKey,$false)} else {$base}
                            # A missing watched root is a valid empty snapshot, allowing later creation to be detected.
                            if ($null -ne $key) { Write-RegistryTree $key $parts.CanonicalPath $sink $errors }
                        } catch { $errors.Add("$($parts.CanonicalPath): $($_.Exception.Message)") }
                        finally { if ($key -and $key -ne $base) {$key.Dispose()}; if ($base) {$base.Dispose()} }
                    }
                }
            } finally { $sink.Dispose(); Write-Progress -Activity 'File snapshot' -Completed; Write-Progress -Activity 'Registry snapshot' -Completed }
            Save-Manifest $job $errors $started $sink.Count
            Write-Host "$($job.Kind): $($sink.Count) entries; $($errors.Count) errors"
            if ($errors.Count) { $incomplete=$true; Write-Warning 'Incomplete snapshot: error details are saved in its manifest.' }
        } else {
            $bm=Read-Manifest $job $job.Before; $am=Read-Manifest $job $job.After
            if (($null -eq $bm) -ne ($null -eq $am)) { throw 'Compare two manifested snapshots or two legacy snapshots; do not mix formats.' }
            if ($bm -and $am) {
                foreach ($field in @('Computer','User','RegistryView')) { if ($bm.$field -cne $am.$field) { throw "Snapshot $field does not match." } }
                if ((@($bm.Scope) -join "`0") -ine (@($am.Scope) -join "`0")) { throw 'Snapshot scopes do not match.' }
            }
            Write-Host "Validating and sorting $($job.Kind) snapshots on disk..."
            $job.OldIncomplete=($bm -and -not $bm.Complete); $job.NewIncomplete=($am -and -not $am.Complete)
            if ($job.OldIncomplete -or $job.NewIncomplete) { $incomplete=$true; Write-Warning 'Incomplete comparison: unmatched entries may be Unknown, not Added/Removed.' }
            $job.SortedBefore=[FolderAB.Core]::Sort($job.Before,($job.Kind -eq 'Registry'),$work)
            if ($bm -and [FolderAB.Core]::LastRowCount -ne $bm.RowCount) { throw 'Before snapshot row count does not match manifest.' }
            $job.SortedAfter=[FolderAB.Core]::Sort($job.After,($job.Kind -eq 'Registry'),$work)
            if ($am -and [FolderAB.Core]::LastRowCount -ne $am.RowCount) { throw 'After snapshot row count does not match manifest.' }
            $job.Fallback=if ($Path) {Full-Path $Path} elseif ($bm -and $job.Kind -eq 'Files') {$bm.Scope[0]} else {''}
        }
    }
    # No report is written until all input jobs have passed validation.
    if ($Mode -eq 'Compare') {
        foreach ($job in $jobs) {
            $reg=$job.Kind -eq 'Registry'
            $header=if ($reg) {@('Change','EntryType','RegistryPath','ValueName','BeforeKind','AfterKind','BeforeData','AfterData')} else {@('Change','FullPath','RelativePath','BeforeMD5','AfterMD5','BeforeSizeBytes','AfterSizeBytes')}
            $sink=[FolderAB.Sink]::new($job.Temp,[string[]]$header); $counts=@{}
            try {
                $iterator=[FolderAB.Core]::OpenCompare($job.SortedBefore,$job.SortedAfter,$reg,$job.OldIncomplete,$job.NewIncomplete,$job.Fallback)
                while ($iterator.MoveNext()) {
                    $row=$iterator.Current
                    $sink.Write($row); $counts[$row[0]]++
                    if ($sink.Count -le 100) { Write-Host "$($row[0]): $($row[1 + [int]$reg])$(if ($reg -and $row[1] -eq 'Value') {'\'+$(if ($row[3]) {$row[3]} else {'(Default)'})})" }
                    if ($sink.Count % 1000 -eq 0) { Write-Progress -Activity 'Comparing snapshots' -Status "$($sink.Count) changes" }
                }
            } finally { if ($iterator) {$iterator.Dispose()}; $sink.Dispose(); Write-Progress -Activity 'Comparing snapshots' -Completed }
            foreach ($type in $counts.Keys) { Write-Host "$($job.Kind) $type`: $($counts[$type])" }
            if ($sink.Count -gt 100) { Write-Host 'Console limited to 100 entries; the CSV contains every change and full path.' }
            if ($sink.Count -eq 0) { Write-Host "No $($job.Kind.ToLowerInvariant()) changes found." }
        }
    }
    foreach ($job in $jobs) {
        Publish-File $job.Temp $job.Dest
        if ($Mode -eq 'Snapshot') { Publish-File ($job.Temp+'.manifest.json') ($job.Dest+'.manifest.json') }
        Write-Host "Saved: $($job.Dest)"
    }
    if ($incomplete) { exit 2 }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
