Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, "codex-watch.vbs", "codex-watch.ps1") & """"
shell.Run cmd, 0, False
