param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,
    [string]$BackupPath,
    [switch]$Preview
)

# Patch existing XML in place so an older installed Expanded version keeps its own data.
$ErrorActionPreference = 'Stop'
if (-not $BackupPath) {
    $BackupPath = Join-Path $PSScriptRoot ('compatibility-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
$ModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
$manifest = [xml]::new()
$manifest.Load((Join-Path $ModulePath 'SubModule.xml'))
if ($manifest.Module.Id.value -ne 'Europe1100Expanded') {
    throw 'ModulePath must point to the Europe1100Expanded module.'
}
$contents = @{}
$originals = @{}
function Read-ModuleXml([string]$RelativePath) {
    if (-not $contents.ContainsKey($RelativePath)) {
        $contents[$RelativePath] = [IO.File]::ReadAllText((Join-Path $ModulePath $RelativePath))
        $originals[$RelativePath] = $contents[$RelativePath]
    }
    $document = [xml]::new()
    $document.LoadXml($contents[$RelativePath])
    return ,$document
}
function Comment-Entries([string]$RelativePath, [string]$XPath, [string]$Reason) {
    $document = Read-ModuleXml $RelativePath
    foreach ($node in $document.SelectNodes($XPath)) {
        $tag = $node.LocalName
        $id = [regex]::Escape($node.GetAttribute('id'))
        $pattern = '(?s)<' + $tag + '\b[^>]*\bid="' + $id + '"[^>]*(?:/>|>.*?</' + $tag + '>)'
        $regex = [regex]::new($pattern)
        if ($regex.Matches($contents[$RelativePath]).Count -ne 1) {
            throw "Cannot safely locate $tag/$id in $RelativePath"
        }
        $contents[$RelativePath] = $regex.Replace($contents[$RelativePath],
            [Text.RegularExpressions.MatchEvaluator]{ param($match)
                '<!-- EoE 1.5.7 compatibility: ' + $Reason + "`r`n" + $match.Value + "`r`n  -->"
            })
    }
}

Comment-Entries 'ModuleData\clans\spclans_pope.xml' "/Factions/Faction[@id='clan_pope_2' or @id='clan_pope_3' or @id='clan_pope_4' or @id='clan_pope_5']" 'legacy papal noble clans are disabled; use the current EoE religious faction.'
Comment-Entries 'ModuleData\kingdoms\spkingdoms_pope.xml' "/Kingdoms/Kingdom[@id='pope']" 'the old pope Kingdom was removed from EoE.'
Comment-Entries 'ModuleData\lords\lords_pope.xml' "/NPCCharacters/NPCCharacter[@id='lord_pope_5a' or @id='lord_pope_5b']" 'the legacy Colonna clan is disabled; retain its characters for reference.'
Comment-Entries 'ModuleData\clans\spclans_seljuk.xml' "/Factions/Faction[@id='clan_seljuk_10']" 'the old Abbasid clan_seljuk_10 was removed; EoE now defines clan_abbasid_1 separately.'
Comment-Entries 'ModuleData\settlements.xml' "/Settlements/Settlement[@owner='Faction.clan_seljuk_10']" 'keep the current EoE owner; clan_seljuk_10 no longer exists.'
Comment-Entries 'ModuleData\snowballs_clans.xml' "/Snowballs/Snowball[@kingdom='pope']" 'the old pope Kingdom no longer exists.'
foreach ($pair in @(@('culture="georgia"', 'culture="georgian"'),
        @('kingdom="goldenhorde"', 'kingdom="prussia"'), @('kingdom="empire_w"', 'kingdom="castile"'))) {
    $contents['ModuleData\snowballs_clans.xml'] = $contents['ModuleData\snowballs_clans.xml'].Replace($pair[0], $pair[1])
}
$manifest = Read-ModuleXml 'SubModule.xml'
if (-not $manifest.SelectSingleNode('/Module/DependedModules/DependedModule[@Id="Europe1100"]')) {
    if (-not $manifest.SelectSingleNode('/Module/DependedModules')) {
        throw 'SubModule.xml has no DependedModules element.'
    }
    $contents['SubModule.xml'] = $contents['SubModule.xml'].Replace('<DependedModules>',
        "<DependedModules>`r`n        <DependedModule Id=`"Europe1100`" />")
}

$changedFiles = @($contents.Keys | Where-Object { $contents[$_] -cne $originals[$_] } | Sort-Object)
foreach ($relative in $changedFiles) {
    $check = [xml]::new()
    $check.LoadXml($contents[$relative])
    Write-Output "Patch: $relative"
}
if ($Preview) { return }
if ($changedFiles.Count -eq 0) {
    Write-Output 'Already patched; no files changed.'
    return
}
$BackupPath = [IO.Path]::GetFullPath($BackupPath)
if (Test-Path -LiteralPath $BackupPath) { throw "Backup path already exists: $BackupPath" }
foreach ($relative in $changedFiles) {
    if ([IO.File]::ReadAllText((Join-Path $ModulePath $relative)) -cne $originals[$relative]) {
        throw "File changed during patch preparation: $relative"
    }
}
foreach ($relative in $changedFiles) {
    $destination = Join-Path $BackupPath $relative
    [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $ModulePath $relative) -Destination $destination
}
foreach ($relative in $changedFiles) {
    [IO.File]::WriteAllText((Join-Path $ModulePath $relative), $contents[$relative], [Text.UTF8Encoding]::new($false))
}
Write-Output "Patched $($changedFiles.Count) XML files. Originals: $BackupPath"
