param($Path)
$errs = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
if ($errs.Count -eq 0) { Write-Host "PARSE OK: $Path" } else { $errs | ForEach-Object { Write-Host ("{0}:{1}  {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message) } }
