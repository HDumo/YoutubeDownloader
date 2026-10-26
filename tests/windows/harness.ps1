$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { $global:HarnessDir }
$src = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'YouTubeMP3.ps1'
$tokens=$null;$errs=$null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$tokens,[ref]$errs)
$want = 'Quote-Arg','Clean-Name','Normalize-Url','Format-Resume','Stop-ProcessTree','Find-Item','Remove-Row','Set-ItemState','Stop-Current','Remove-Selected','Retry-Selected','Get-WindowSeconds','Trim-StartTimes','Get-NextAllowedTime','Start-Download','Handle-Line','Pump-Process','Fill-SecondUnit','Init-UnitPair','Get-PauseSeconds','Update-Row','Set-Pause','Clear-Pause','Toggle-Pause'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
# ---- stubs for GUI-only things ----
function Get-StatusColor($s) { $null }
function Save-Queue {}
function Save-Settings {}
function Update-PauseUI {}
$UnitNames   = @('Days','Hours','Minutes','Seconds')
$UnitSeconds = @{ Days=86400; Hours=3600; Minutes=60; Seconds=1 }
$YtDlp = Join-Path $here 'fake-ytdlp.sh'; $ToolsDir='/tmp'
$script:Items = New-Object System.Collections.ArrayList
$script:StartTimes = New-Object System.Collections.ArrayList
$script:Current=$null;$script:Proc=$null;$script:OutTask=$null;$script:ErrTask=$null;$script:ExitSeen=$null;$script:Paused=$false;$script:ResumeAt=$null;$script:WasBusy=$false
function New-Row { [pscustomobject]@{ ForeColor=$null; ListView=$null; SubItems=@(1..5 | % { [pscustomobject]@{Text=''} }) } }
function New-Item2($url,$kind='MP3',$name='',$h=0) {
  $i=[pscustomobject]@{Id=($script:Items.Count+1);Url=$url;Name=$name;Folder='/tmp/ytout';Kind=$kind;Height=$h;Display=$(if ($name) { $name } else { '(original title)' });Text='Queued';Status='Queued';Row=(New-Row);LastError=$null;RemoveWhenDone=$false}
  [void]$script:Items.Add($i); $i }
$fail = 0
function Check($name,$cond){ if($cond){Write-Host "PASS  $name"} else {Write-Host "FAIL  $name"; $script:fail++} }

# ---- pure helpers ----
Check 'Clean-Name strips ext+illegal' ((Clean-Name ' My: Song?.mp3 ') -eq 'My_ Song_')
Check 'Clean-Name strips .mp4' ((Clean-Name 'Clip.MP4') -eq 'Clip')
Check 'Normalize-Url adds https' ((Normalize-Url 'youtu.be/abc') -eq 'https://youtu.be/abc')
Check 'Normalize-Url rejects junk' ($null -eq (Normalize-Url 'hello world'))
Check 'Quote-Arg plain' ((Quote-Arg 'a b') -eq '"a b"')
Check 'Quote-Arg embedded quote' ((Quote-Arg 'a"b') -eq '"a\"b"')
Check 'Quote-Arg trailing backslash' ((Quote-Arg 'C:\x\') -eq '"C:\x\\"')

# ---- unit dropdown rules ----
function New-Combo { $c=[pscustomobject]@{Items=(New-Object System.Collections.ArrayList);SelectedItem=$null;Enabled=$true;SelectedIndex=-1}
  $c | Add-Member ScriptMethod AddRange { param($a) foreach($x in $a){[void]$this.Items.Add($x)} } -Force
  $c | Add-Member ScriptMethod Clear {} ; $c.Items | Add-Member ScriptMethod Clear { $this.RemoveRange(0,$this.Count) } -Force; $c }
function New-Num($v=0){ [pscustomobject]@{Value=[decimal]$v;Enabled=$true} }
$c1=New-Combo;$c2=New-Combo;$n2=New-Num 5
$c1.Items.AddRange([object[]]$UnitNames) 2>$null; foreach($u in $UnitNames){[void]$c1.Items.Add($u)} 
$c1.SelectedItem='Hours'
$second=$c2; $second | Add-Member ScriptMethod AddRange { param($a) foreach($x in $a){[void]$this.Items.Add($x)} } -Force
Fill-SecondUnit $c1 $n2 $c2
Check 'Hours -> Minutes,Seconds' (($c2.Items -join ',') -eq 'Minutes,Seconds' -and $c2.Enabled)
$c1.SelectedItem='Days'; Fill-SecondUnit $c1 $n2 $c2
Check 'Days -> Hours,Minutes,Seconds' (($c2.Items -join ',') -eq 'Hours,Minutes,Seconds')
$c1.SelectedItem='Seconds'; Fill-SecondUnit $c1 $n2 $c2
Check 'Seconds -> disabled, value 0' (-not $c2.Enabled -and -not $n2.Enabled -and $n2.Value -eq 0)

# ---- limit maths ----
$numCount=New-Num 3; $numA=New-Num 1; $numB=New-Num 30
$cmbU1=[pscustomobject]@{SelectedItem='Hours'}; $cmbU2=[pscustomobject]@{SelectedItem='Minutes';Enabled=$true}
Check 'window = 1h30m = 5400s' ((Get-WindowSeconds) -eq 5400)
Check 'no limit when none started' ($null -eq (Get-NextAllowedTime))
$t0=(Get-Date).AddMinutes(-80); $t1=(Get-Date).AddMinutes(-60); $t2=(Get-Date).AddMinutes(-10)
foreach($t in $t0,$t1,$t2){[void]$script:StartTimes.Add($t)}
Check '3 in window -> blocked until oldest+90m' ((Get-NextAllowedTime) -and [math]::Abs(((Get-NextAllowedTime)-$t0.AddSeconds(5400)).TotalSeconds) -lt 1)
$script:StartTimes.Clear(); foreach($t in (Get-Date).AddMinutes(-200),$t1,$t2){[void]$script:StartTimes.Add($t)}
Check 'old start trimmed -> allowed' ($null -eq (Get-NextAllowedTime))
$numCount.Value=0
Check 'limit 0 = unlimited' ($null -eq (Get-NextAllowedTime))

# ---- pause maths ----
$numPA=New-Num 2; $numPB=New-Num 15; $cmbPU1=[pscustomobject]@{SelectedItem='Days'}; $cmbPU2=[pscustomobject]@{SelectedItem='Hours';Enabled=$true}
Check 'pause 2 days + 15 hours' ((Get-PauseSeconds) -eq (2*86400+15*3600))
$btnPause=[pscustomobject]@{Text=''}; $miPause=[pscustomobject]@{Text=''}
Toggle-Pause; Check 'toggle -> paused indefinite' ($script:Paused -and -not $script:ResumeAt)
Toggle-Pause; Check 'toggle -> resumed' (-not $script:Paused)
Set-Pause (Get-Date).AddHours(1); Check 'timed pause holds ResumeAt' ($script:Paused -and $script:ResumeAt)
Clear-Pause; Check 'Clear-Pause clears' (-not $script:Paused -and -not $script:ResumeAt)

# ---- downloads through the fake yt-dlp ----
function Run-Item($item,$maxSec=20){
  Start-Download $item; $sw=[Diagnostics.Stopwatch]::StartNew()
  while($script:Current -and $sw.Elapsed.TotalSeconds -lt $maxSec){ Pump-Process; Start-Sleep -Milliseconds 100 }
}
$env:FAKE_ARGS_LOG = Join-Path ([IO.Path]::GetTempPath()) 'ytdl-fake-args.txt'; Remove-Item $env:FAKE_ARGS_LOG -ErrorAction SilentlyContinue
$a=New-Item2 'https://youtu.be/ok1' 'MP3' '100% Mix'; Run-Item $a
$argsMp3 = (Get-Content $env:FAKE_ARGS_LOG -Raw)
Check 'mp3 args: -x --audio-format mp3' ($argsMp3 -match '-x' -and $argsMp3 -match 'audio-format' -and $argsMp3 -match 'mp3')
Check 'mp3 args: % in a custom name is escaped (%%)' ($argsMp3 -like '*100%% Mix.%(ext)s*')
Remove-Item $env:FAKE_ARGS_LOG -ErrorAction SilentlyContinue
Check 'mp3 ok -> Done, custom name kept as the title' ($a.Status -eq 'Done' -and $a.Display -eq '100% Mix')
$b=New-Item2 'https://youtu.be/mp4' 'MP4' '' 720; Run-Item $b
$argsMp4 = (Get-Content $env:FAKE_ARGS_LOG -Raw)
Check 'mp4 args: merge to mp4, 720p cap that tolerates unknown height' ($argsMp4 -match '--merge-output-format' -and $argsMp4 -match 'height<=\?720' -and $argsMp4 -notmatch '(?m)^-x$')
Check 'mp4 ok -> Done, .fNNN stripped' ($b.Status -eq 'Done' -and $b.Display -eq 'Video Title')
$c=New-Item2 'https://youtu.be/fail'; Run-Item $c
Check 'failure -> Failed + reason' ($c.Status -eq 'Failed' -and $c.Text -like '*Video unavailable*')
$a2=New-Item2 'https://youtu.be/ok2'; Run-Item $a2
Check 'mp3 ok -> Done + title from yt-dlp output' ($a2.Status -eq 'Done' -and $a2.Display -eq 'Nice Song')
$d=New-Item2 'https://youtu.be/slow'; Start-Download $d
$sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.Elapsed.TotalSeconds -lt 3){ Pump-Process; Start-Sleep -Milliseconds 100 }
Check 'slow one is Downloading' ($d.Status -eq 'Downloading' -and $script:Current -and $d.Text -like 'Downloading*')
$d.RemoveWhenDone=$true; Stop-Current
$sw=[Diagnostics.Stopwatch]::StartNew(); while($script:Current -and $sw.Elapsed.TotalSeconds -lt 10){ Pump-Process; Start-Sleep -Milliseconds 100 }
Check 'cancel -> process gone, current cleared' (-not $script:Current)
Check 'cancel + RemoveWhenDone -> row removed from items' (-not ($script:Items -contains $d))
# args actually sent
$captured = Get-Content /tmp/yttest/lastargs.txt -ErrorAction SilentlyContinue
Write-Host "---- failures: $fail"
