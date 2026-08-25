@echo off
rem Relay into Git Bash so `sandbox` works from cmd and PowerShell too.
rem Pass %* as real argv to `bash -l <script>`, NOT a -c "sandbox %*" string:
rem in the -c form cmd's quotes are consumed and re-parsed by bash's word
rem splitter, so `-p "do the thing"` collapses to `-p do the thing` (and a
rem parenthesis becomes a bash syntax error). As argv, bash hands each word to
rem the script unre-parsed. Resolve the sibling sandbox script via %~dp0
rem (trailing backslash), backslashes to forward slashes for Git Bash.
set "SBDIR=%~dp0"
"%ProgramFiles%\Git\bin\bash.exe" -l "%SBDIR:\=/%sandbox" %*
