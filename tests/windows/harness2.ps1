$ErrorActionPreference='Stop'
$global:HarnessDir = $PSScriptRoot
. { $s = Get-Content (Join-Path $PSScriptRoot 'harness.ps1') -Raw; $cut = $s.IndexOf('# ---- pure helpers ----'); Invoke-Expression $s.Substring(0,$cut) }
function Mk($url,$status){ $i = New-Item2 $url; $i.Status=$status; $i.Text=$status
  $i.Row | Add-Member NoteProperty Tag $i.Id -Force
  $i.Row | Add-Member ScriptMethod Remove { $this.ListView = $null; $script:removedRows += $this.Tag } -Force
  $i.Row.ListView = 'lv'; $i }
$script:removedRows=@()
$q=Mk 'https://youtu.be/q' 'Queued'; $f=Mk 'https://youtu.be/f' 'Done'; $x=Mk 'https://youtu.be/x' 'Failed'
$lblStatus=[pscustomobject]@{Text=''}
$list=[pscustomobject]@{SelectedItems=@()}
# remove queued + done + failed in one go
$list.SelectedItems=@($q.Row,$f.Row,$x.Row); Remove-Selected
Check 'removes queued, done and failed rows' ($script:Items.Count -eq 0 -and $script:removedRows.Count -eq 3)
# nothing selected -> helpful message
$list.SelectedItems=@(); Remove-Selected
Check 'no selection -> message' ($lblStatus.Text -like '*Click one or more rows*')
# running one: cancel + removal after exit
$r=Mk 'https://youtu.be/slow' 'Queued'; Start-Download $r
$sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.Elapsed.TotalSeconds -lt 2){ Pump-Process; Start-Sleep -Milliseconds 100 }
$list.SelectedItems=@($r.Row); Remove-Selected
$sw=[Diagnostics.Stopwatch]::StartNew(); while($script:Current -and $sw.Elapsed.TotalSeconds -lt 10){ Pump-Process; Start-Sleep -Milliseconds 100 }
Check 'running row cancelled and removed' (-not $script:Current -and -not ($script:Items -contains $r))
# retry
$z=Mk 'https://youtu.be/z' 'Failed'; $list.SelectedItems=@($z.Row); Retry-Selected
Check 'retry puts failed back to Queued' ($z.Status -eq 'Queued')
Write-Host "---- failures: $fail"
