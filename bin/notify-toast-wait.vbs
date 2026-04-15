Set oShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
title = WScript.Arguments(0)
If WScript.Arguments.Count > 1 Then
  body = WScript.Arguments(1)
Else
  body = ""
End If
If WScript.Arguments.Count > 2 Then
  hWnd = WScript.Arguments(2)
Else
  hWnd = "0"
End If
oShell.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\notify-toast-wait.ps1"" -Title """ & title & """ -Body """ & body & """ -hWndParam """ & hWnd & """", 0, False
