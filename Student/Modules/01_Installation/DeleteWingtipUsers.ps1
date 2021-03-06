Import-Module ActiveDirectory

$WingtipDomain = "DC=wingtip,DC=com"
$ouWingtipUsersName = "Wingtip Users"
$ouWingtipUsersPath = "OU={0},{1}" -f $ouWingtipUsersName, $WingtipDomain
$ouWingtipUsers = Get-ADOrganizationalUnit -Filter { name -eq $ouWingtipUsersName}
if($ouWingtipUsers -ne $null){
  Remove-ADOrganizationalUnit -Identity $ouWingtipUsers -Recursive -Confirm:$false
}

Write-Host "Press ENTER to continue"
Read-Host