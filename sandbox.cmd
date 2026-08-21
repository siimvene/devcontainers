@echo off
rem Relay into Git Bash so `sandbox` works from cmd and PowerShell too.
"%ProgramFiles%\Git\bin\bash.exe" -lc "sandbox %*"
