# Offline check: Show log > Copy hides the app folder (\, / or \\ between its parts, any case) and the Windows user name.
# Loads Hide-Personal from CaptionsApp.ps1 (nothing else runs). usage: powershell -File bench/test_log_privacy.ps1
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\CaptionsApp.ps1", [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Hide-Personal" }, $true)
$fakeRoot = "C:\Users\$env:USERNAME\OneDrive - Contoso\Desktop\private-captions-1.3.1"
Invoke-Expression $fn.Extent.Text.Replace('$PSScriptRoot', '$fakeRoot')
$u = $env:USERNAME
$in = "load C:\Users\$u\OneDrive - Contoso\Desktop\private-captions-1.3.1\.cache\whisper`n" +
      "File 'c:\\users\\$u\\onedrive - contoso\\desktop\\private-captions-1.3.1\\audioWhisper\\x.py'`n" +
      "cfg C:/Users/$u/OneDrive - Contoso/Desktop/private-captions-1.3.1/Profiles/lite.yaml`n" +
      "hf C:/Users/$u/.cache/huggingface ok"
$want = "load <app folder>\.cache\whisper`n" +
        "File '<app folder>\\audioWhisper\\x.py'`n" +
        "cfg <app folder>/Profiles/lite.yaml`n" +
        "hf C:/Users/<user>/.cache/huggingface ok"
$out = Hide-Personal $in
if ($out -ne $want) { "FAIL:`n$out"; exit 1 }
if ($out -match [regex]::Escape($u) -or $out -match "Contoso") { "FAIL: leaked"; exit 1 }
# the log file never holds what was said (Hide-Said, captions.ps1)
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\app\captions.ps1", [ref]$null, [ref]$null)
Invoke-Expression $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Hide-Said" }, $true).Extent.Text
$out = Hide-Said "ready`r`nTranscribe: secret words`r`nskipping... result:  {'text': 'secret'}`r`nTranscribe (OSC): secret`r`nTranscribe: `r`nok"
if ($out -ne "ready`r`nTranscribe: (text hidden)`r`nskipping... result: (text hidden)`r`nTranscribe (OSC): (text hidden)`r`nTranscribe: (text hidden)`r`nok") { "FAIL said:`n$out"; exit 1 }
"log ok"
