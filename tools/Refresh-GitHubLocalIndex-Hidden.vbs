' Hidden launcher for GitHubLocalIndex scheduled tasks.
Dim fso, shell, here, repoRoot, modeArg, psScript, command, whereCode, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot = fso.GetParentFolderName(here)
psScript = here & "\Refresh-GitHubLocalIndex.ps1"
modeArg = ""

If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "-checkonly" Then
        modeArg = " -CheckOnly"
    Else
        WScript.Echo "Unsupported GitHubLocalIndex refresh mode: " & WScript.Arguments(0)
        WScript.Quit 2
    End If
End If

shell.CurrentDirectory = repoRoot
whereCode = shell.Run("cmd.exe /d /c where pwsh.exe >nul 2>nul", 0, True)
If whereCode = 0 Then
    command = "pwsh.exe -NoProfile -File """ & psScript & """" & modeArg
Else
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & psScript & """" & modeArg
End If

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
