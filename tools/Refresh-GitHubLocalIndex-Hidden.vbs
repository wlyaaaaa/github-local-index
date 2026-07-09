' Read-only hidden launcher for the GitHubLocalIndex consistency task.
Dim fso, shell, here, repoRoot, checkScript, command, whereCode, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count <> 1 Then
    WScript.Quit 2
End If
If LCase(WScript.Arguments(0)) <> "checkonly" And LCase(WScript.Arguments(0)) <> "-checkonly" Then
    WScript.Quit 2
End If

here = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot = fso.GetParentFolderName(here)
checkScript = here & "\Test-GitHubLocalIndexConsistency.ps1"
shell.CurrentDirectory = repoRoot

whereCode = shell.Run("cmd.exe /d /c where pwsh.exe >nul 2>nul", 0, True)
If whereCode <> 0 Then
    WScript.Quit 3
End If
command = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & checkScript & """ -SkipFetch"

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
