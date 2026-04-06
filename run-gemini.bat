@echo off
setlocal

set "CIREBRONX_PROVIDER=gemini"
set "GEMINI_API_KEY="
set "OPENAI_MODEL=gemini-2.5-flash"
@rem set "OPENAI_MODEL=gemini-3.1-flash-live-preview"

if "%~1"=="" (
  "%~dp0zig-out\bin\cirebronx.exe"
) else (
  "%~dp0zig-out\bin\cirebronx.exe" %*
)
