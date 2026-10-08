#Requires -Version 7.0
# Invoke-JML.ps1: reads an HR CSV and creates, moves, or disables users in Entra ID.

# ---- 1. SETTINGS: what the script needs from you when you run it ----
[CmdletBinding(SupportsShouldProcess)]   # lets you add -WhatIf for a dry run
param(
  [Parameter(Mandatory)][string]$CsvPath,    # which HR file to read
  [Parameter(Mandatory)][string]$Domain,     # your tenant domain, like yourlab.onmicrosoft.com
  [string]$MapPath = './config-groups.csv',  # the department-to-groups table
  [string]$LogDir  = './logs'                # where the results log is saved
)
$ErrorActionPreference = 'Stop'   # stop on an error instead of silently continuing
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logFile = Join-Path $LogDir ('jml-{0}.csv' -f (Get-Date -Format yyyyMMdd-HHmmss))

# Load the department-to-groups table, e.g. $map['Finance'] = SG-Finance, LIC-ENTRA-P2
$map = @{}
Import-Csv $MapPath | ForEach-Object { $map[$_.Department] = @($_.Groups -split ';') }
$script:log = [System.Collections.Generic.List[object]]::new()   # an empty list that collects results

# ---- 2. HELPERS: small reusable pieces ----
function Write-Log($Action, $User, $Result, $Detail = '') {
  # Adds one line to the results list and prints it on screen
  $script:log.Add([pscustomobject]@{ Time = (Get-Date -Format s); Action = $Action; User = $User; Result = $Result; Detail = $Detail })
  Write-Host ('[{0}] {1} {2} {3}' -f $Result, $Action, $User, $Detail)
}
function Find-User($EmployeeId) {
  # Looks up a person by employee ID
  Get-MgUser -Filter ('employeeId eq ''{0}''' -f $EmployeeId) -Property Id,UserPrincipalName,Department,JobTitle -ConsistencyLevel eventual -CountVariable ct
}
function Get-GroupId($Name) {
  # Turns a group name into the ID that Graph needs
  (Get-MgGroup -Filter ('displayName eq ''{0}''' -f $Name)).Id
}
function New-RandomPassword {
  # Makes a random 24-character password nobody ever sees; the new hire signs in with a Temporary Access Pass instead
  $c = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%'
  -join (1..24 | ForEach-Object { $c[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($c.Length)] })
}

# ---- 3. THE THREE JOBS ----
function Invoke-Join {   # NEW HIRE
  [CmdletBinding(SupportsShouldProcess)] param($row)
  # Build the sign-in name, like ava.brooks@yourlab.onmicrosoft.com
  $upn = ('{0}.{1}@{2}' -f $row.FirstName, $row.LastName, $Domain).ToLower()
  # If the account already exists, do nothing (this makes re-running safe)
  if (Get-MgUser -Filter ('userPrincipalName eq ''{0}''' -f $upn)) { Write-Log Join $upn Skipped 'already exists'; return }
  # With -WhatIf, stop here and only print what would happen
  if (-not $PSCmdlet.ShouldProcess($upn, 'Create user, groups, manager, TAP')) { return }
  # Create the account
  $user = New-MgUser -AccountEnabled -DisplayName ('{0} {1}' -f $row.FirstName, $row.LastName) `
    -GivenName $row.FirstName -Surname $row.LastName -UserPrincipalName $upn `
    -MailNickname $upn.Split('@')[0] -Department $row.Department -JobTitle $row.JobTitle `
    -EmployeeId $row.EmployeeId -EmployeeHireDate ([datetime]$row.StartDate) -UsageLocation 'US' `
    -PasswordProfile @{ Password = (New-RandomPassword); ForceChangePasswordNextSignIn = $true }
  # Add them to each group for their department (this also gives them the P2 license)
  foreach ($g in $map[$row.Department]) { New-MgGroupMember -GroupId (Get-GroupId $g) -DirectoryObjectId $user.Id }
  # Set their manager, if the HR file lists one
  if ($row.ManagerEmployeeId) {
    $mgr = Find-User $row.ManagerEmployeeId
    if ($mgr) { Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{ '@odata.id' = ('https://graph.microsoft.com/v1.0/users/{0}' -f $mgr.Id) } }
  }
  # Make a one-time sign-in code (a Temporary Access Pass) so they can sign in and set up MFA
  Start-Sleep -Seconds 5
  $tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $user.Id -BodyParameter @{ lifetimeInMinutes = 480; isUsableOnce = $true }
  Write-Host ('TAP for {0}: {1}' -f $upn, $tap.TemporaryAccessPass)   # shown once on screen, never written to the log
  Write-Log Join $upn Success ('groups: ' + ($map[$row.Department] -join ','))
}

function Invoke-Move {   # DEPARTMENT TRANSFER
  [CmdletBinding(SupportsShouldProcess)] param($row)
  $u = Find-User $row.EmployeeId
  if (-not $u) { Write-Log Move $row.EmployeeId Failed 'not found'; return }
  $old = @($map[$u.Department]); $new = @($map[$row.NewDepartment])   # old and new group lists
  if (-not $PSCmdlet.ShouldProcess($u.UserPrincipalName, ('Move {0} -> {1}' -f $u.Department, $row.NewDepartment))) { return }
  # Remove groups they no longer need, add the new ones, then update department and title
  foreach ($g in ($old | Where-Object { $_ -notin $new })) { Remove-MgGroupMemberByRef -GroupId (Get-GroupId $g) -DirectoryObjectId $u.Id }
  foreach ($g in ($new | Where-Object { $_ -notin $old })) { New-MgGroupMember -GroupId (Get-GroupId $g) -DirectoryObjectId $u.Id }
  Update-MgUser -UserId $u.Id -Department $row.NewDepartment -JobTitle $row.NewTitle
  Write-Log Move $u.UserPrincipalName Success ('{0} -> {1}' -f $u.Department, $row.NewDepartment)
}

function Invoke-Leave {   # LEAVER
  [CmdletBinding(SupportsShouldProcess)] param($row)
  $u = Find-User $row.EmployeeId
  if (-not $u) { Write-Log Leave $row.EmployeeId Failed 'not found'; return }
  if (-not $PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Disable, revoke sessions, remove groups')) { return }
  Update-MgUser -UserId $u.Id -AccountEnabled:$false      # block sign-in
  $null = Revoke-MgUserSignInSession -UserId $u.Id        # kick out anyone already signed in
  foreach ($m in (Get-MgUserMemberOf -UserId $u.Id -All)) {
    switch ($m.AdditionalProperties['@odata.type']) {
      '#microsoft.graph.group' {   # remove from groups (dynamic groups cannot be edited by hand, so warn instead)
        try { Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $u.Id }
        catch { Write-Log Leave $u.UserPrincipalName Warning ('could not remove from {0} (dynamic group?)' -f $m.Id) }
      }
      '#microsoft.graph.directoryRole' { Write-Log Leave $u.UserPrincipalName Review ('holds admin role {0}' -f $m.AdditionalProperties['displayName']) }   # flag for a human
    }
  }
  Write-Log Leave $u.UserPrincipalName Success 'disabled, sessions revoked, groups removed'
}

# ---- 4. MAIN: sign in, then handle each row of the HR file ----
Connect-MgGraph -Scopes 'User.ReadWrite.All','Group.ReadWrite.All','GroupMember.ReadWrite.All','User.RevokeSessions.All','UserAuthenticationMethod.ReadWrite.All' -NoWelcome
foreach ($row in Import-Csv $CsvPath) {
  try {
    switch ($row.Action) {
      'Join'  { Invoke-Join $row }
      'Move'  { Invoke-Move $row }
      'Leave' { Invoke-Leave $row }
      default { Write-Log $row.Action $row.EmployeeId Skipped 'unknown action' }
    }
  } catch { Write-Log $row.Action $row.EmployeeId Failed $_.Exception.Message }   # one bad row never stops the rest
}
$script:log | Export-Csv $logFile -NoTypeInformation   # save the results to a CSV