' Windows 11 System Tray Styler for Claude (created by Ryan Peddigrew): hidden launcher for the usage service.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "\ClaudeUsageTray.ps1""", 0, False
