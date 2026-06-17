param(
    [ValidateSet("sync", "push", "pull", "scan", "status")]
    [string]$Mode = "sync",

    [string]$Message = "chore: sync cn-trader updates",

    [string]$Branch = "main",

    [string]$Remote = "origin",

    [string]$HostName = "github.com"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Log-Info {
    param([string]$Msg)
    Write-Host "[INFO] $Msg" -ForegroundColor Cyan
}

function Log-Ok {
    param([string]$Msg)
    Write-Host "[OK] $Msg" -ForegroundColor Green
}

function Log-Warn {
    param([string]$Msg)
    Write-Host "[WARN] $Msg" -ForegroundColor Yellow
}

function Log-Bad {
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
}

function Run-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs,

        [switch]$AllowFail
    )

    $output = & git @GitArgs 2>&1
    $code = $LASTEXITCODE

    if ($code -ne 0 -and -not $AllowFail) {
        Log-Bad "git $($GitArgs -join ' ') failed"
        @($output) | ForEach-Object { Write-Host $_ }
        throw "Git command failed"
    }

    return [pscustomobject]@{
        Code  = $code
        Lines = @($output)
        Text  = (@($output) -join "`n")
    }
}

function Ensure-GitRepo {
    $r = Run-Git -GitArgs @("rev-parse", "--is-inside-work-tree")
    if ($r.Text.Trim() -ne "true") {
        throw "Current directory is not a Git repository"
    }

    $root = (Run-Git -GitArgs @("rev-parse", "--show-toplevel")).Text.Trim()
    Set-Location $root
    Log-Info "Repository root: $root"
}

function Ensure-SshRemote {
    Log-Info "Checking GitHub remote URL..."

    $url = (Run-Git -GitArgs @("remote", "get-url", $Remote)).Text.Trim()
    $hostEscaped = [regex]::Escape($HostName)

    $sshPattern = '^git@' + $hostEscaped + ':.+/.+\.git$'
    if ($url -match $sshPattern) {
        Log-Ok "Remote already uses SSH: $url"
        return
    }

    $sshUrlPattern = "^ssh://git@$hostEscaped/(.+?)(?:\.git)?$"
    if ($url -match $sshUrlPattern) {
        $repoPath = $Matches[1] -replace "\.git$", ""
        $sshUrl = "git@{0}:{1}.git" -f $HostName, $repoPath
        Run-Git -GitArgs @("remote", "set-url", $Remote, $sshUrl) | Out-Null
        Log-Ok "Converted ssh:// URL to SSH URL: $sshUrl"
        return
    }

    $httpsPattern = "^https://$hostEscaped/(.+?)(?:\.git)?$"
    if ($url -match $httpsPattern) {
        $repoPath = $Matches[1] -replace "\.git$", ""
        $sshUrl = "git@{0}:{1}.git" -f $HostName, $repoPath
        Run-Git -GitArgs @("remote", "set-url", $Remote, $sshUrl) | Out-Null
        Log-Ok "Converted HTTPS URL to SSH URL: $sshUrl"
        return
    }

    Log-Bad "Remote URL is not a recognized GitHub URL: $url"
    throw "Please set SSH remote manually, for example: git remote set-url $Remote git@github.com:user/repo.git"
}

function Ensure-Branch {
    $current = (Run-Git -GitArgs @("branch", "--show-current")).Text.Trim()

    if ($current -ne $Branch) {
        Log-Bad "Current branch is [$current], expected [$Branch]"
        Write-Host "Run this first:"
        Write-Host "  git checkout $Branch"
        throw "Wrong branch"
    }

    Log-Ok "Current branch: $current"
}

function Ensure-GitIgnoreRules {
    Log-Info "Checking .gitignore rules..."

    $ignoreFile = ".gitignore"
    if (-not (Test-Path $ignoreFile)) {
        New-Item -ItemType File -Path $ignoreFile | Out-Null
    }

    $rules = @(
        "",
        "# cn-trader sensitive files",
        ".env",
        ".env.*",
        "!.env.example",
        "*.key",
        "*.pem",
        "*.p12",
        "*.pfx",
        "*.crt",
        "*.sqlite",
        "*.sqlite3",
        "*.db",
        "*.mdb",
        "*.kdbx",
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "*password*",
        "*passwd*",
        "*secret*",
        "*token*",
        "*credential*",
        "data/*.db",
        "data/**/*.db",
        "data/*.sqlite",
        "data/**/*.sqlite",
        "instance/*.db",
        "instance/*.sqlite"
    )

    $current = ""
    if (Test-Path $ignoreFile) {
        $current = Get-Content $ignoreFile -Raw -ErrorAction SilentlyContinue
    }

    $changed = $false
    foreach ($rule in $rules) {
        if ([string]::IsNullOrWhiteSpace($rule)) {
            continue
        }

        if ($current -notmatch [regex]::Escape($rule)) {
            Add-Content -Path $ignoreFile -Value $rule
            $changed = $true
        }
    }

    if ($changed) {
        Log-Ok ".gitignore updated"
    } else {
        Log-Ok ".gitignore already has sensitive rules"
    }
}

function Get-RepoStatus {
    $r = Run-Git -GitArgs @("status", "--porcelain") -AllowFail
    return @($r.Lines)
}

function Has-WorkingChanges {
    $status = Get-RepoStatus
    return ($status.Count -gt 0)
}

function Get-ChangedFiles {
    $set = New-Object "System.Collections.Generic.HashSet[string]"

    $a = Run-Git -GitArgs @("diff", "--name-only") -AllowFail
    $b = Run-Git -GitArgs @("diff", "--cached", "--name-only") -AllowFail
    $c = Run-Git -GitArgs @("ls-files", "--others", "--exclude-standard") -AllowFail

    foreach ($f in @($a.Lines + $b.Lines + $c.Lines)) {
        if ([string]::IsNullOrWhiteSpace($f)) {
            continue
        }
        [void]$set.Add($f.Trim())
    }

    return @($set)
}

function Test-PathIsSensitive {
    param([string]$File)

    $normalized = $File -replace "\\", "/"

    if ($normalized -match "^\.env\.example$") {
        return $false
    }

    $blockedPatterns = @(
        '(^|/)\.env($|[./])',
        '\.(pem|key|p12|pfx|sqlite|sqlite3|db|mdb|kdbx)$',
        '(^|/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)$',
        '(?i)(password|passwd|secret|token|credential|private[_-]?key|api[_-]?key|account)'
    )

    foreach ($p in $blockedPatterns) {
        if ($normalized -match $p) {
            return $true
        }
    }

    return $false
}

function Scan-Privacy {
    Log-Info "Running privacy scan..."

    $files = Get-ChangedFiles

    if ($files.Count -eq 0) {
        Log-Ok "No changed files to scan"
        return
    }

    $contentPatterns = @(
        'sk-[A-Za-z0-9_-]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'ghp_[A-Za-z0-9]{20,}',
        'AKIA[0-9A-Z]{16}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|refresh[_-]?token|authorization|bearer|password|passwd|db[_-]?pass|database[_-]?url)\s*[:=]\s*[''"]?[^''"\r\n]{8,}',
        '(?i)(postgres|mysql|redis|mongodb)://[^ \r\n]+:[^ \r\n]+@'
    )

    $textExts = @(
        ".py", ".ps1", ".js", ".ts", ".json", ".yaml", ".yml",
        ".toml", ".ini", ".cfg", ".md", ".txt", ".html", ".css",
        ".vue", ".sh", ".bat", ".cmd", ".sql", ".example"
    )

    $blockedItems = New-Object "System.Collections.Generic.List[string]"

    foreach ($file in $files) {
        if (Test-PathIsSensitive -File $file) {
            $blockedItems.Add("Sensitive file path: $file")
            continue
        }

        if (-not (Test-Path $file)) {
            continue
        }

        $item = Get-Item $file -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        if ($item.PSIsContainer) {
            continue
        }

        if ($item.Length -gt 2097152) {
            Log-Warn "Skip large file content scan: $file"
            continue
        }

        $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        $base = [System.IO.Path]::GetFileName($file).ToLowerInvariant()

        if (($textExts -notcontains $ext) -and ($base -ne ".gitignore")) {
            continue
        }

        try {
            $content = Get-Content -Path $file -Raw -ErrorAction Stop
        } catch {
            Log-Warn "Cannot read file, skip content scan: $file"
            continue
        }

        foreach ($p in $contentPatterns) {
            if ($content -match $p) {
                $blockedItems.Add("Possible secret in file: $file")
                break
            }
        }
    }

    if ($blockedItems.Count -gt 0) {
        Log-Bad "Privacy scan failed. Commit blocked."
        Write-Host ""
        foreach ($item in $blockedItems) {
            Write-Host " - $item" -ForegroundColor Red
        }
        Write-Host ""
        Log-Warn "Remove real keys, tokens, passwords, database files, account files, or move them to local .env."
        throw "Privacy scan failed"
    }

    Log-Ok "Privacy scan passed"
}

function Fetch-Remote {
    Log-Info "Fetching $Remote/$Branch..."
    Run-Git -GitArgs @("fetch", "--prune", $Remote, $Branch) | Out-Null
    Log-Ok "Fetch done"
}

function Get-AheadBehind {
    $remoteRef = "$Remote/$Branch"
    $result = Run-Git -GitArgs @("rev-list", "--left-right", "--count", "HEAD...$remoteRef") -AllowFail

    if ($result.Code -ne 0) {
        Log-Bad "Cannot compare HEAD and $remoteRef"
        $result.Lines | ForEach-Object { Write-Host $_ }
        throw "Compare failed"
    }

    $parts = $result.Text.Trim() -split "\s+"

    return [pscustomobject]@{
        Ahead  = [int]$parts[0]
        Behind = [int]$parts[1]
    }
}

function Safe-Pull {
    Fetch-Remote
    $ab = Get-AheadBehind

    if ($ab.Ahead -gt 0 -and $ab.Behind -gt 0) {
        Log-Bad "Local and remote branches have diverged. Ahead=$($ab.Ahead), Behind=$($ab.Behind)"
        Write-Host ""
        Write-Host "Manual fix recommended:"
        Write-Host "  git status"
        Write-Host "  git log --oneline --graph --decorate --all -20"
        Write-Host "  git pull --rebase $Remote $Branch"
        throw "Branch diverged"
    }

    if ($ab.Behind -eq 0) {
        Log-Ok "No remote updates"
        return
    }

    Log-Warn "Remote has $($ab.Behind) new commit(s). Pulling safely..."

    $hadChanges = Has-WorkingChanges

    if ($hadChanges) {
        Log-Warn "Local changes detected. Scanning and stashing before pull..."
        Scan-Privacy
        Run-Git -GitArgs @("stash", "push", "-u", "-m", "cn-trader-auto-stash-before-pull") | Out-Null
    }

    try {
        Run-Git -GitArgs @("pull", "--ff-only", $Remote, $Branch) | Out-Null
        Log-Ok "Pull done"
    } finally {
        if ($hadChanges) {
            Log-Warn "Restoring local changes from stash..."
            $pop = Run-Git -GitArgs @("stash", "pop") -AllowFail
            if ($pop.Code -ne 0) {
                Log-Bad "stash pop failed. Please run git status and resolve conflicts."
                $pop.Lines | ForEach-Object { Write-Host $_ }
                throw "Stash pop failed"
            }
            Log-Ok "Local changes restored"
        }
    }
}

function Commit-LocalChanges {
    if (-not (Has-WorkingChanges)) {
        Log-Ok "No local changes to commit"
        return
    }

    Log-Info "Local changes detected. Running privacy scan before commit..."
    Scan-Privacy

    Log-Info "Running git add -A..."
    Run-Git -GitArgs @("add", "-A") | Out-Null

    Log-Info "Running privacy scan again after staging..."
    Scan-Privacy

    $staged = Run-Git -GitArgs @("diff", "--cached", "--name-only") -AllowFail
    if (@($staged.Lines).Count -eq 0) {
        Log-Ok "No staged changes to commit"
        return
    }

    Log-Info "Committing: $Message"
    Run-Git -GitArgs @("commit", "-m", $Message) | Out-Null
    Log-Ok "Commit done"
}

function Push-Remote {
    Fetch-Remote
    $ab = Get-AheadBehind

    if ($ab.Ahead -gt 0 -and $ab.Behind -gt 0) {
        Log-Bad "Local and remote branches diverged before push. Stop."
        Write-Host "Manual fix recommended:"
        Write-Host "  git pull --rebase $Remote $Branch"
        throw "Branch diverged before push"
    }

    if ($ab.Behind -gt 0) {
        Log-Warn "Remote has updates before push. Pulling first..."
        Safe-Pull
        Fetch-Remote
        $ab = Get-AheadBehind
    }

    if ($ab.Ahead -eq 0) {
        Log-Ok "No local commits to push"
        return
    }

    Log-Info "Pushing to GitHub..."
    Run-Git -GitArgs @("push", $Remote, $Branch) | Out-Null
    Log-Ok "Push done"
}

function Show-Status {
    Fetch-Remote

    $url = (Run-Git -GitArgs @("remote", "get-url", $Remote)).Text.Trim()
    $ab = Get-AheadBehind
    $dirty = Has-WorkingChanges

    Write-Host ""
    Write-Host "========== cn-trader git status ==========" -ForegroundColor Cyan
    Write-Host "Remote: $Remote"
    Write-Host "URL:    $url"
    Write-Host "Branch: $Branch"
    Write-Host "Ahead:  $($ab.Ahead)"
    Write-Host "Behind: $($ab.Behind)"
    Write-Host "Dirty:  $dirty"
    Write-Host ""

    git status --short
}

function Main {
    Write-Host ""
    Write-Host "========== cn-trader GitHub sync ==========" -ForegroundColor Cyan
    Write-Host "Mode:   $Mode"
    Write-Host "Branch: $Branch"
    Write-Host ""

    Ensure-GitRepo
    Ensure-SshRemote
    Ensure-Branch
    Ensure-GitIgnoreRules

    switch ($Mode) {
        "status" {
            Show-Status
        }

        "scan" {
            Scan-Privacy
            Log-Ok "Scan mode done"
        }

        "pull" {
            Safe-Pull
            Log-Ok "Pull mode done"
        }

        "push" {
            Commit-LocalChanges
            Push-Remote
            Log-Ok "Push mode done"
        }

        "sync" {
            Safe-Pull
            Commit-LocalChanges
            Push-Remote
            Log-Ok "Sync mode done"
        }
    }

    Write-Host ""
    Log-Ok "All done"
}

try {
    Main
} catch {
    Write-Host ""
    Log-Bad $_.Exception.Message
    Write-Host ""
    Log-Warn "Stopped. No unsafe operation continued."
    exit 1
}

