$env:CIREBRONX_PROVIDER = 'gemini'
$env:GEMINI_API_KEY = ''
$env:OPENAI_MODEL = 'gemini-2.5-flash'

if ($args.Count -eq 0) {
    & "$PSScriptRoot\zig-out\bin\cirebronx.exe"
} else {
    & "$PSScriptRoot\zig-out\bin\cirebronx.exe" @args
}
