Get-Content .env.local | ForEach-Object {
    if ($_ -match '^([^#][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
    }
}
$dbUrl = [System.Environment]::GetEnvironmentVariable('SUPABASE_DB_URL', 'Process')
Write-Host "Pushing DB migrations to Supabase using npx supabase --db-url..."
npx supabase db push --db-url "$dbUrl"
