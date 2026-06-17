Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

#region ------ CONFIGURATION -------------------------------------------------

$Config = [pscustomobject]@{
    Origin    = 'https://www.internship.edutainer.in'
    LoginPage = 'https://www.internship.edutainer.in/login'
    LoginPost = 'https://www.internship.edutainer.in/login'

    # Entry URL for each enrolled course. Edutainer redirects/serves the
    # right starting lecture for you - no lecture_uuid needed here.
    # Add/remove lines if your enrollments change.
    CourseUrls = @(
        'https://www.internship.edutainer.in/student/my-course/React-Full-stack-WebApp-development-Skills',
        'https://www.internship.edutainer.in/student/my-course/Python-Essentials-and-Libraries-for-Data-Science',
        'https://www.internship.edutainer.in/student/my-course/Skill-enhancement-with-Data-structure-algorithm-C-language',
        'https://www.internship.edutainer.in/student/my-course/MS-Excel-Basic-to-Advance-level'
    )

    MaxLecturesPerCourse = 200    # safety cap so a bad nextLectureRoute loop can't run forever
    DelayMs              = 250    # pause between requests - be polite to the server
    RetryCount           = 3
    RetryDelayMs         = 1500
}

#endregion --------------------------------------------------------------------

#region ------ LOGGING ---------------------------------------------------------

$Global:LogFile = $null

function Initialize-Logging {
    $logDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EdutainerLogs'
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    $Global:LogFile = Join-Path $logDir ('Edutainer_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Add-Content -Path $Global:LogFile -Encoding UTF8 -Value ('[{0}] Session started' -f (Get-Date))
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $Global:LogFile) { return }
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    Add-Content -Path $Global:LogFile -Encoding UTF8 -Value "[$ts][$Level] $Message"
}

#endregion --------------------------------------------------------------------

#region ------ HTML PARSING HELPERS --------------------------------------------

function Get-HiddenField {
    param([string]$Html, [string]$ClassName)
    # 1. First, find the HTML tag that contains the required class
    if ($Html -match "(?i)<[^>]*class\s*=\s*['`"]$ClassName['`"][^>]*>") {
        $tag = $matches[0]
        # 2. Extract the value attribute from that specific tag, regardless of order
        if ($tag -match "(?i)value\s*=\s*['`"]([^'`"]*)['`"]") {
            return $matches[1]
        }
    }
    return ''
}

function Get-LectureFields {
    param([string]$Html)
    $fields = [pscustomobject]@{
        CourseId       = Get-HiddenField $Html 'course_id'
        LectureId      = Get-HiddenField $Html 'lecture_id'
        EnrollmentId   = Get-HiddenField $Html 'enrollment_id'
        LectureTitle   = Get-HiddenField $Html 'lecture_title'
        CompletedRoute = Get-HiddenField $Html 'videoCompletedRoute'
        NextRoute      = Get-HiddenField $Html 'nextLectureRoute'
        NextId         = Get-HiddenField $Html 'nextLectureId'
    }

    # Fallback: If it couldn't find the hidden field, look for a standard 'Next' hyperlink
    if (-not $fields.NextRoute) {
        if ($Html -match '(?i)<a[^>]+href\s*=\s*["'']([^"'']+)["''][^>]*>.*?Next.*?</a>') {
            $fields.NextRoute = $matches[1]
        }
    }
    
    return $fields
}

#endregion --------------------------------------------------------------------

#region ------ HTTP HELPERS -----------------------------------------------------

function Invoke-Retry {
    param([scriptblock]$Action, [string]$Label)
    $lastErr = $null
    for ($i = 0; $i -lt $Config.RetryCount; $i++) {
        try {
            Start-Sleep -Milliseconds $Config.DelayMs
            Write-Log $Label
            return & $Action
        }
        catch {
            $lastErr = $_
            Write-Log "FAILED $Label (try $($i+1)/$($Config.RetryCount)): $($_.Exception.Message)" 'WARN'
            Start-Sleep -Milliseconds $Config.RetryDelayMs
        }
    }
    throw $lastErr
}

function Invoke-Login {
    param([string]$Email, [securestring]$Password)

    # Wipe the plaintext password from memory as soon as we're done with it.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    Write-Log "GET $($Config.LoginPage)"
    $loginPageResp = Invoke-WebRequest -Uri $Config.LoginPage -WebSession $session -UseBasicParsing -ErrorAction Stop

    if ($loginPageResp.Content -notmatch 'name="_token"\s+value="([^"]+)"') {
        throw 'Could not find the CSRF _token on the login page. Edutainer may have changed its login form - re-check with DevTools.'
    }
    $token = $matches[1]

    $body = @{
        _token   = $token
        email    = $Email
        password = $plain
    }

    Write-Log "POST $($Config.LoginPost)"
    Write-Log '[login body redacted]' 'DEBUG'
    $resp = Invoke-WebRequest -Uri $Config.LoginPost -Method POST -Body $body -WebSession $session -UseBasicParsing -ErrorAction Stop

    # If we're still looking at a password field after POSTing, login didn't succeed.
    if ($resp.Content -match 'name="password"') {
        throw 'Login failed - double check your email/password. (Still seeing the sign-in form after submitting.)'
    }

    return $session
}

function Get-Page {
    param($Session, [string]$Url)
    Invoke-Retry -Label "GET $Url" -Action {
        Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -ErrorAction Stop
    }
}

function Complete-Lecture {
    param($Session, [string]$CompletedRoute, [string]$CourseId, [string]$LectureId, [string]$EnrollmentId)
    $url = "$CompletedRoute" + "?course_id=$CourseId&lecture_id=$LectureId&enrollment_id=$EnrollmentId"
    Invoke-Retry -Label "Complete lecture $LectureId (course $CourseId)" -Action {
        Invoke-WebRequest -Uri $url -WebSession $Session -UseBasicParsing -ErrorAction Stop
    }
}

#endregion --------------------------------------------------------------------

#region ------ DISPLAY -----------------------------------------------------------

function Show-Banner {
    Write-Host ''
    Write-Host '===========================================================' -ForegroundColor Cyan
    Write-Host '   EDUTAINER - AUTO COMPLETE' -ForegroundColor White
    Write-Host '===========================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Show-Summary {
    param([int]$Completed, [int]$Failed, [string]$Elapsed)
    Write-Host ''
    Write-Host '===========================================================' -ForegroundColor Cyan
    Write-Host "  Completed : $Completed lecture(s)" -ForegroundColor Green
    if ($Failed -gt 0) {
        Write-Host "  Failed    : $Failed lecture(s)" -ForegroundColor Red
    }
    Write-Host "  Time      : $Elapsed" -ForegroundColor White
    Write-Host '===========================================================' -ForegroundColor Cyan
    Write-Host ''
    if ($Global:LogFile) {
        Write-Host "  Logs saved to: $Global:LogFile" -ForegroundColor DarkGray
        Write-Host ''
    }
}

#endregion --------------------------------------------------------------------

#region ------ MAIN --------------------------------------------------------------

function Start-EdutainerSkipper {
    Initialize-Logging
    Show-Banner

    Write-Host '  Email    : ' -NoNewline -ForegroundColor DarkGray
    $email = Read-Host
    Write-Host '  Password : ' -NoNewline -ForegroundColor DarkGray
    $secPass = Read-Host -AsSecureString
    Write-Host ''

    Write-Host '[1/2] Logging in...' -ForegroundColor Cyan
    $session = Invoke-Login -Email $email -Password $secPass
    Write-Host '      OK' -ForegroundColor Green
    Write-Host ''

    Write-Host '[2/2] Processing courses...' -ForegroundColor Cyan
    Write-Host ''

    $totalCompleted = 0
    $totalFailed = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $courseIndex = 0
foreach ($courseUrl in $Config.CourseUrls) {
        $courseIndex++
        Write-Host "  Course $courseIndex/$($Config.CourseUrls.Count)" -ForegroundColor White
        Write-Host "    $courseUrl" -ForegroundColor DarkGray

        try {
            $page = Get-Page -Session $session -Url $courseUrl
        }
        catch {
            Write-Host "    Could not open course: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Could not open course $courseUrl : $($_.Exception.Message)" 'ERROR'
            Write-Host ''
            continue
        }

        # --- NEW LOGIC: Harvest all lecture links from the sidebar/menu ---
        # This regex looks for any URL in the page containing 'lecture_uuid' or 'lecture_id'
        $linkRegex = [System.Text.RegularExpressions.Regex]::new('href\s*=\s*["'']([^"'']+(?:lecture_uuid|lecture_id)=[^"'']+)["'']', 'IgnoreCase')
        $allLinks = $linkRegex.Matches($page.Content) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique

        if ($allLinks.Count -eq 0) {
            Write-Host '    [!] Could not find any lecture links in the course menu. The page structure might be blocking the script.' -ForegroundColor Yellow
            Write-Log "No menu links found for $courseUrl" 'WARN'
            Write-Host ''
            continue
        }

        Write-Host "    -> Found $($allLinks.Count) total items in course modules. Processing..." -ForegroundColor Cyan
        
        $lectureCountThisCourse = 0
        $iter = 0

        # Loop through our harvested list of links instead of relying on the "Next" button
        foreach ($link in $allLinks) {
            $iter++
            
            # Format the URL just in case the site uses relative paths (e.g., /student/...)
            $fullUrl = $link
            if ($fullUrl -match '^/') { $fullUrl = $Config.Origin + $fullUrl }

            Write-Host "    [$iter/$($allLinks.Count)] " -NoNewline -ForegroundColor DarkGray

            try {
                $lecturePage = Get-Page -Session $session -Url $fullUrl
                $fields = Get-LectureFields -Html $lecturePage.Content
                
                # If a link is a Quiz or Assignment, it won't have video fields. We can safely skip it.
                if (-not $fields.CourseId -or -not $fields.LectureId) {
                    Write-Host "SKIP (Not a video lesson)" -ForegroundColor DarkYellow
                    continue
                }

                $resp = Complete-Lecture -Session $session -CompletedRoute $fields.CompletedRoute `
                    -CourseId $fields.CourseId -LectureId $fields.LectureId -EnrollmentId $fields.EnrollmentId
                
                Write-Log "Completed lecture $($fields.LectureId) (course $($fields.CourseId)): HTTP $($resp.StatusCode)"
                Write-Host "DONE (Lecture $($fields.LectureId))" -ForegroundColor Green
                
                $totalCompleted++
                $lectureCountThisCourse++
            }
            catch {
                Write-Host "FAIL" -ForegroundColor Red
                Write-Log "Failed to complete link $fullUrl : $($_.Exception.Message)" 'ERROR'
                $totalFailed++
            }
            
            # Safety check to prevent infinite loops if the site bugs out
            if ($iter -ge $Config.MaxLecturesPerCourse) {
                Write-Host "    Hit safety cap of $($Config.MaxLecturesPerCourse) lectures - stopping this course." -ForegroundColor Yellow
                break
            }
        }

        Write-Host "    -> $lectureCountThisCourse video(s) completed in this course" -ForegroundColor Cyan
        Write-Host ''
    }

    $sw.Stop()
    $elapsed = "$([math]::Floor($sw.Elapsed.TotalMinutes))m $($sw.Elapsed.Seconds)s"
    Show-Summary -Completed $totalCompleted -Failed $totalFailed -Elapsed $elapsed
    Write-Log "Done. Completed=$totalCompleted Failed=$totalFailed Time=$elapsed"
}

#endregion --------------------------------------------------------------------

try {
    Start-EdutainerSkipper
}
catch {
    Write-Host ''
    Write-Host "  Fatal error: $($_.Exception.Message)" -ForegroundColor Red
    if ($Global:LogFile) {
        Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
        Write-Host "  See log for details: $Global:LogFile" -ForegroundColor DarkGray
    }
}
finally {
    Write-Host ''
}
