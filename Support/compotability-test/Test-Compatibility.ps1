param(
    [string]$GamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Mount & Blade II Bannerlord',
    [string]$ExpandedPath = (Split-Path $PSScriptRoot -Parent)
)

# Read-only check using the installed game's XML merger and schemas. No game launch.
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $GamePath 'bin\Win64_Shipping_Client\TaleWorlds.Library.dll')
Add-Type -Path (Join-Path $GamePath 'bin\Win64_Shipping_Client\TaleWorlds.ObjectSystem.dll')
$mergeMethod = [TaleWorlds.ObjectSystem.MBObjectManager].GetMethod(
    'MergeTwoXmls', [Reflection.BindingFlags]'Public,NonPublic,Static')
$categories = @('SPCultures', 'NPCCharacters', 'Heroes', 'Factions', 'Kingdoms', 'Settlements')
$documents = @{}
$schemas = @{}
$required = @{}
$changed = @{}
$problems = [Collections.Generic.List[string]]::new()

foreach ($category in $categories) {
    $schemaPath = Join-Path $GamePath "XmlSchemas\$category.xsd"
    [TaleWorlds.ObjectSystem.XmlResource]::ReadXsdFileAndExtractInformation($schemaPath)
    $schema = [xml]::new()
    $schema.Load($schemaPath)
    $ns = [Xml.XmlNamespaceManager]::new($schema.NameTable)
    $ns.AddNamespace('xs', 'http://www.w3.org/2001/XMLSchema')
    $root = $schema.SelectSingleNode("/xs:schema/xs:element[@name='$category']", $ns)
    $entry = $root.SelectSingleNode('xs:complexType/*/xs:element[@name]', $ns)
    $required[$category] = @($entry.SelectNodes('xs:complexType/xs:attribute[@use="required"]', $ns) |
        ForEach-Object { $_.GetAttribute('name') })
    $schemas[$category] = $schemaPath
    $documents[$category] = [xml]::new()
    $documents[$category].LoadXml('<' + $root.GetAttribute('name') + '/>')
    $changed[$category] = @{}
}

$modulePaths = @('Native', 'SandBoxCore', 'Sandbox', 'StoryMode', 'BirthAndDeath', 'Europe1100') |
    ForEach-Object { Join-Path $GamePath "Modules\$_" }
$modulePaths += $ExpandedPath
foreach ($modulePath in $modulePaths) {
    $manifestPath = Join-Path $modulePath 'SubModule.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
    $manifest = [xml]::new()
    $manifest.Load($manifestPath)
    foreach ($resource in $manifest.SelectNodes('/Module/Xmls/XmlNode')) {
        $category = $resource.XmlName.GetAttribute('id')
        if ($category -notin $categories) { continue }
        $gameTypes = @($resource.SelectNodes('IncludedGameTypes/GameType') |
            ForEach-Object { $_.GetAttribute('value') })
        if ($gameTypes.Count -gt 0 -and 'Campaign' -notin $gameTypes) { continue }
        $resourcePath = Join-Path $modulePath ('ModuleData\' + $resource.XmlName.GetAttribute('path'))
        if (Test-Path -LiteralPath $resourcePath -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $resourcePath -Filter '*.xml' | Sort-Object Name)
        } elseif (Test-Path -LiteralPath ($resourcePath + '.xml')) {
            $files = @(Get-Item -LiteralPath ($resourcePath + '.xml'))
        } else {
            throw "Missing XML resource: $resourcePath"
        }
        foreach ($file in $files) {
            $xsltPath = [IO.Path]::ChangeExtension($file.FullName, '.xslt')
            if (Test-Path -LiteralPath $xsltPath) {
                $transform = [Xml.Xsl.XslCompiledTransform]::new()
                $transform.Load($xsltPath)
                $buffer = [IO.MemoryStream]::new()
                $transform.Transform($documents[$category], $null, $buffer)
                $buffer.Position = 0
                $transformed = [xml]::new()
                $transformed.Load($buffer)
                $buffer.Dispose()
                $documents[$category] = $transformed
            }
            $incoming = [xml]::new()
            $incoming.Load($file.FullName)
            if ($modulePath -eq $ExpandedPath) {
                foreach ($node in $incoming.DocumentElement.SelectNodes('*[@id]')) {
                    $changed[$category][$node.GetAttribute('id')] = $file.FullName
                }
            }
            # Reflection needs unwrapped XmlDocuments under Windows PowerShell 5.1.
            $arguments = [object[]]::new(4)
            $arguments[0] = $documents[$category].PSObject.BaseObject
            $arguments[1] = $incoming.PSObject.BaseObject
            $arguments[2] = $schemas[$category].PSObject.BaseObject
            $arguments[3] = $false
            $documents[$category] = $mergeMethod.Invoke($null, $arguments)
        }
    }
}

$prefixes = @{
    Culture = 'SPCultures'; NPCCharacter = 'NPCCharacters'; Hero = 'Heroes'
    Faction = 'Factions'; Kingdom = 'Kingdoms'; Settlement = 'Settlements'
}
$indexes = @{}
foreach ($category in $categories) {
    $indexes[$category] = @{}
    foreach ($node in $documents[$category].DocumentElement.SelectNodes('*[@id]')) {
        $indexes[$category][$node.GetAttribute('id')] = $node
    }
}
foreach ($category in $categories) {
    foreach ($id in $changed[$category].Keys) {
        $node = $indexes[$category][$id]
        if ($null -eq $node) {
            $problems.Add("$category/$id disappeared during XML merging")
            continue
        }
        foreach ($attribute in $required[$category]) {
            if (-not $node.HasAttribute($attribute)) {
                $problems.Add("$category/$id has no required '$attribute' after merging")
            }
        }
        foreach ($attribute in $node.SelectNodes('.//@*')) {
            if ($attribute.Value -match '^(Culture|NPCCharacter|Hero|Faction|Kingdom|Settlement)\.(.+)$') {
                $targetCategory = $prefixes[$Matches[1]]
                $targetId = $Matches[2]
                # Hero definitions can also be created from is_hero NPCCharacters.
                $heroNpc = $targetCategory -eq 'Heroes' -and
                    $indexes.NPCCharacters.ContainsKey($targetId) -and
                    $indexes.NPCCharacters[$targetId].GetAttribute('is_hero') -eq 'true'
                if (-not $indexes[$targetCategory].ContainsKey($targetId) -and -not $heroNpc) {
                    $problems.Add("$category/$id references missing $($attribute.Value)")
                }
            }
        }
    }
    Write-Output ("{0}: {1} merged records, {2} Expanded records checked" -f
        $category, $indexes[$category].Count, $changed[$category].Count)
}

$snowballs = [xml]::new()
$snowballs.Load((Join-Path $ExpandedPath 'ModuleData\snowballs_clans.xml'))
foreach ($node in $snowballs.SelectNodes('/Snowballs/Snowball')) {
    foreach ($pair in @(@('kingdom', 'Kingdoms'), @('culture', 'SPCultures'))) {
        $value = $node.GetAttribute($pair[0])
        if ($value -and -not $indexes[$pair[1]].ContainsKey($value)) {
            $problems.Add("Snowball/$($node.GetAttribute('id')) references missing $($pair[0]) '$value'")
        }
    }
}
if ($problems.Count) {
    $problems | ForEach-Object { Write-Output "ERROR: $_" }
    throw "$($problems.Count) compatibility problems found."
}
Write-Output 'PASS: required attributes and campaign object references resolve after game XML merging.'
