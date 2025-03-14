# Params for the script
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$pathArray,  # The input path (file or folder)

    [Parameter(Mandatory = $false)]
    [string]$outputFolderPath # Default to "output" folder in the same directory as the input file
)

$VerbosePreference = 'Continue'
$DEFAULT_OUTPUT_FOLDER = "output"

$global:ProcessedFiles = @{}  # Track processed files globally

enum ImportType {
    Unknown
    Include
    Use
}

enum LogicType {
    Unknown
    Module
    Function
}

enum ScadEntryType {
    Comment
    Variable
    Include
    Use
    Function
    Module
    Empty
}

class ScadFile {
    [string]$Name
    [string]$Path
    [string]$Content
    [string]$ExpandedContent
    [Import[]]$Imports
    [Logic[]]$Logic
    [string[]]$Variables
    [bool]$IsProcessed

    # Default constructor
    ScadFile() {
        $this.Imports = @()
        $this.Logic = @()
        $this.Variables = @()
        $this.IsProcessed = $false
    }

    # Constructor with path and content
    ScadFile([string]$path, [string]$content) {
        $this.Path = $path
        $this.Content = $content
        $this.ExpandedContent = $content
        $this.Name = Split-Path $path -Leaf
        $this.IsProcessed = $false
        $this.Imports = @()
        $this.Logic = @()
        $this.Variables = @()
    }
}

class Import : ScadFile {
    [ImportType]$Type
    [String]$ImportName

    # Constructor for imported OpenSCAD files
    Import([string]$path, [string]$content, [ImportType]$type) : base($path, $content) {
        $this.Type = $type
    }
}

class Logic {
    [string]$Name
    [string]$Content
    [LogicType]$Type

    Logic() {}

    Logic([string]$name, [string]$content, [LogicType]$type) {
        $this.Name = $name
        $this.Content = $content
        $this.Type = $type
    }
}

# Define a unified class for both comments and variables
class ScadEntry {
    [ScadEntryType]$Type       # "Comment" or "Variable"
    [string]$Content    # Full text (for comments) or variable name
    [string]$Value      # Variable value (only for variables)
    [string]$Section    # Associated comment block
    [int]$LineNumber    # Line number in the file

    ScadEntry([ScadEntryType]$type, [string]$content, [string]$value, [string]$section, [int]$line) {
        $this.Type = $type
        $this.Content = $content
        $this.Value = $value
        $this.Section = $section
        $this.LineNumber = $line
    }

    [string] ToString() {
        return "[Line $($this.LineNumber)] $($this.Type): $($this.Content)"
    }
}

class ScadParser {
    [string[]]$Lines
    [System.Collections.Generic.List[ScadEntry]]$Entries

    ScadParser([string[]]$lines) {
        $this.Lines = $lines
        $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
    }

    [void] Parse() {
        $insideMultiLineComment = $false
        $multiLineCommentBuffer = ""
        $currentCommentBlock = @()
        $insideFunction = $false
        $insideModule = $false
        $functionBuffer = ""
        $moduleBuffer = ""
        $bracketCount = 0

        for ($i = 0; $i -lt $this.Lines.Length; $i++) {
            $line = $this.Lines[$i]
            $trimmedLine = $line.Trim()
            $lineNumber = $i + 1

            # Capture includes and use statements
            if ($trimmedLine -match '^\s*include\s*<(.*?)>') {
                $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Include, $matches[1], "", "", $lineNumber))
                continue
            }

            if ($trimmedLine -match '^\s*use\s*<(.*?)>') {
                $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Use, $matches[1], "", "", $lineNumber))
                continue
            }

            # Capture full function definition
            if ($insideFunction) {
                $functionBuffer += "`n" + $trimmedLine
                $bracketCount += ([regex]::Matches($trimmedLine, '{')).Count
                $bracketCount -= ([regex]::Matches($trimmedLine, '}')).Count

                if ($bracketCount -eq 0) {
                    $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Function, $functionBuffer, "", "", $lineNumber))
                    $insideFunction = $false
                    $functionBuffer = ""
                }
                continue
            }
            if ($trimmedLine -match '^\s*function\s+([\w_]+)\s*\((.*?)\)\s*=') {
                $insideFunction = $true
                $bracketCount = 1
                $functionBuffer = $trimmedLine
                continue
            }

            # Capture full module definition
            if ($insideModule) {
                $moduleBuffer += "`n" + $trimmedLine
                $bracketCount += ([regex]::Matches($trimmedLine, '{')).Count
                $bracketCount -= ([regex]::Matches($trimmedLine, '}')).Count

                if ($bracketCount -eq 0) {
                    $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Module, $moduleBuffer, "", "", $lineNumber))
                    $insideModule = $false
                    $moduleBuffer = ""
                }
                continue
            }

            if ($trimmedLine -match '^\s*module\s+([\w_]+)\s*\((.*?)\)\s*{?') {
                $insideModule = $true
                $bracketCount = 1
                $moduleBuffer = $trimmedLine
                continue
            }

            # Handle inline multi-line comment (/* ... */ on the same line)
            if ($trimmedLine -match '/\*.*\*/') {
                $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Comment, $trimmedLine, "", "", $lineNumber))
                $currentCommentBlock += $trimmedLine
                continue
            }

            # Start of multi-line comment
            if ($trimmedLine -match '^/\*') { 
                $insideMultiLineComment = $true
                $multiLineCommentBuffer = "$trimmedLine"
                continue
            }

            # Capture multi-line comment content
            if ($insideMultiLineComment) {
                $multiLineCommentBuffer += "`n$trimmedLine"
                if ($trimmedLine -match '\*/$') { 
                    $insideMultiLineComment = $false
                    $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Comment, $multiLineCommentBuffer, "", "", $lineNumber))
                    $currentCommentBlock = @($multiLineCommentBuffer)
                }
                continue
            }

            # Capture single-line comments
            if ($trimmedLine -match '^//') {
                $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Comment, $trimmedLine, "", "", $lineNumber))
                $currentCommentBlock += $trimmedLine
                continue
            }

            # Match variable assignments
            if ($trimmedLine -match '^([\w_]+)\s*=\s*([^;]+);') {
                $varName = $matches[1].Trim()
                $varValue = $matches[2].Trim()
                $inlineComment = ""

                # Capture inline comment after semicolon
                if ($trimmedLine -match ';\s*(//.*)') {
                    $inlineComment = $matches[1].Trim()
                }

                # Associate variable with the most recent comment block
                $this.Entries.Add([ScadEntry]::new(
                    [ScadEntryType]::Variable, 
                    $varName, 
                    $varValue, 
                    ($currentCommentBlock -join "`n"), 
                    $lineNumber
                ))

                # Reset comment block after using it
                $currentCommentBlock = @()
                continue
            }

            # Handle empty lines
            if ($trimmedLine -eq "") {
                $this.Entries.Add([ScadEntry]::new([ScadEntryType]::Empty, "", "", "", $lineNumber))
            }
        }
    }

    [void] PrintResults() {
        Write-Host "`n=== Parsed OpenSCAD File ==="
        foreach ($entry in $this.Entries) { Write-Output $entry.ToString() }
    }
}

function Invoke-ProcessScadFilesInFolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$folderPath,
        [Parameter(Mandatory = $true)]
        [string]$outputFolderPath
    )

    $scadFiles = Get-ChildItem -Path $folderPath -Filter "*.scad" -Recurse -ErrorAction SilentlyContinue
    if (-not $scadFiles) {
        Write-Warning "No .scad files found in: $folderPath"
        return
    }

    foreach ($scadFile in $scadFiles) {
        Invoke-ProcessScadFile -filePath $scadFile.FullName -outputFolderPath $outputFolderPath
    }
}

function Invoke-ProcessScadFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [string]$outputFolderPath
    )

    Write-Verbose "Processing file: $filePath"

    $fileDetails = Get-Item -Path $filePath

    # Read the file content and put it in a Scadfile object
    $fileContent = Get-Content -Path $filePath -Raw

    $lines = $fileContent -split "`r?`n"

    $parser = [ScadParser]::new($lines)
    $parser.Parse()

    # $scadFile = New-Object ScadFile -ArgumentList $fileDetails.FullName, $fileContent

    # if (-not $scadFile) {
    #     Write-Error "Failed to create ScadFile object for file: $filePath"
    #     return
    # }

    # Analyze the file content to extract imports, logic, and variables
    $scadFile = Invoke-ParseScadFile -scadFile $scadFile
}

function Invoke-ParseScadFile {
    param (
        [Parameter(Mandatory = $true)]
        [ScadFile]$scadFile
    )

    Write-Verbose "Analyzing file: $($scadFile.Path)"

    # Get logic from the file content
    $scadFile.Logic = Get-Logic-From-Content -content $scadFile.Content

    # Get imports from the file content
    $scadFile.Imports = Get-Imports-From-Content -content $scadFile.Content

    # Get variables from the file content
    $scadFile.Variables = Get-Variable-Content -content $scadFile.Content

    # Write variables to a string in order
    $variableString = ""
    foreach ($variable in $scadFile.Variables) {
        $variableString += "$($variable.Name) = $($variable.Value)`n"
    }

    $scadFile.ExpandedContent += "`n# Variables`n$variableString"

    return $scadFile
} 

function Get-Logic-From-Content {
    param (
        [Parameter(Mandatory = $true)]
        [string]$content
    )

    $currentLogic = $null
    $currentContent = @()
    $type = $null

    # Ensure regex captures leading spaces (avoiding partial matches)
    $moduleRegex = '^\s*module\s+(\w+)\s*\((.*?)\)\s*{'
    $functionRegex = '^\s*function\s+(\w+)\s*\((.*?)\)\s*{' 

    # Read content line by line
    $lines = $content -split "`r?`n"
    $logic = @()
    foreach ($line in $lines) {
        # Check if the line is a module definition
        if ($line -match $moduleRegex) {
            $moduleName = $matches[1]
            $moduleParams = $matches[2]
            $currentLogic = [Logic]::new($moduleName, $line, [LogicType]::Module)
            $currentContent = @()
            $type = [LogicType]::Module
        } elseif ($line -match $functionRegex) {
            $functionName = $matches[1]
            $functionParams = $matches[2]
            $currentLogic = [Logic]::new($functionName, $line, [LogicType]::Function)
            $currentContent = @()
            $type = [LogicType]::Function
        } elseif ($line -match '^\s*}') {
            if ($currentLogic) {
                $currentLogic.Content = $currentContent -join "`n"
                $currentLogic.Type = $type
                $logic += $currentLogic
                $currentLogic = $null
                $currentContent = @()
            }
        } elseif ($currentLogic) {
            $currentContent += $line
        }
    }

    if ($currentLogic) {
        $logic += New-Object Logic -ArgumentList $currentLogic, ($currentContent -join "`n"), $type
    }

    if ($logic.Count -eq 1) {
        return @($logic)
    }

    return $logic
}

function Get-Imports-From-Content {
    param (
        [Parameter(Mandatory = $true)]
        [string]$content
    )
    
    $importTypes = [ImportType]::GetValues([ImportType])
    $imports = @()

    foreach ($type in $importTypes) {
        if ($type -eq [ImportType]::Unknown) {
            continue
        }   
            $regexPattern = if ($type -eq [ImportType]::Use) { 
                '(?i)use\s+<(.+?)>' 
            } 
            elseif ($type -eq [ImportType]::Include) {
                 '(?i)include\s+<(.+?)>' 
            } 
            else { contine }

            $regexMatches = [regex]::Matches($content, $regexPattern)
            foreach ($match in $regexMatches) {
                $importName = $match.Groups[1].Value
                $absolutePath = Resolve-Path -Path (Join-Path -Path (Split-Path $filePath) -ChildPath $importReference) -ErrorAction SilentlyContinue
                $name = if ($absolutePath) { Split-Path -Leaf $absolutePath } else { $importReference }
                $import = [Import]::new($name, $match.Value, $type)
                $import.ImportName = $importName
                $import.Path = $absolutePath

                if ($absolutePath) {
                    $importContent = Get-Content -Path $absolutePath -Raw -ErrorAction SilentlyContinue
                    if ($importContent) {
                        $import.Content = $importContent
                        $import.Imports = Get-Imports-From-Content -content $importContent
                        $import.Logic = Get-Logic-From-Content -content $importContent
                    }
                } else {
                    Write-Warning "Failed to resolve path for import: $importName"
                }

                $imports += $import
        }
    }

    return $imports
}

function Get-Variables-From-Content {
    param (
        [Parameter(Mandatory = $true)]
        [string]$content
    )

    $variables = @()
    $variableRegex = '^\s*(\w+)\s*=\s*(.*?);'

    $lines = $content -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -match $variableRegex) {
            $variableName = $matches[1]
            $variableValue = $matches[2]
            $variables += [PSCustomObject]@{
                Name = $variableName
                Value = $variableValue
            }
        }
    }

    return $variables
}

function Get-Variable-Content {
    param (
        [Parameter(Mandatory = $true)]
        [string]$content
    )

    # Variables to track comments and results
    $insideMultiLineComment = $false
    $multiLineCommentBuffer = ""
    $orderedResults = @()

    # Split content into lines
    $scadContent = $content -split "`r?`n"

    # Process each line in order
# Process each line while preserving order
    for ($i = 0; $i -lt $scadContent.Length; $i++) {
        $line = $scadContent[$i]
        $trimmedLine = $line.Trim()
        $lineNumber = $i + 1  # Adjust line number (1-based index)

        # Debugging: Show progress
        Write-Host "[Processing Line $lineNumber]: $trimmedLine"

        # Handle inline multi-line comment (/* ... */ on the same line)
        if ($trimmedLine -match '/\*.*\*/') {
            $orderedResults += @{ Type = "Comment"; Value = "[$lineNumber] $trimmedLine"; Line = $lineNumber }
            $currentCommentBlock += "[$lineNumber] $trimmedLine"
            continue
        }

        # Start of multi-line comment
        if ($trimmedLine -match '^/\*') { 
            $insideMultiLineComment = $true
            $multiLineCommentBuffer = "[$lineNumber] $trimmedLine"
            continue
        }

        # Continue capturing multi-line comment
        if ($insideMultiLineComment) {
            $multiLineCommentBuffer += "`n[$lineNumber] $trimmedLine"
            if ($trimmedLine -match '\*/$') { 
                $insideMultiLineComment = $false
                # $orderedResults += @{ Type = "Comment"; Value = $multiLineCommentBuffer; Line = $lineNumber }
                $this.Entries.Add([ScadEntry]::new("Comment", $multiLineCommentBuffer, "", "", $lineNumber))
                $currentCommentBlock = @($multiLineCommentBuffer)
            }
            continue
        }

        # Capture single-line comments
        if ($trimmedLine -match '^//') {
            $orderedResults += @{ Type = "Comment"; Value = "[$lineNumber] $trimmedLine"; Line = $lineNumber }
            $currentCommentBlock += "[$lineNumber] $trimmedLine"
            continue
        }

        # Skip includes, modules, and functions
        if ($trimmedLine -match '^\s*(include|module|function)\s') {
            continue
        }

        # Match variable assignments
        if ($trimmedLine -match '^([\w_]+)\s*=\s*([^;]+);') {
            $varName = $matches[1].Trim()
            $varValue = $matches[2].Trim()

            # Capture inline comment
            $inlineComment = ""
            if ($trimmedLine -match ';\s*(//.*)') {
                $inlineComment = $matches[1].Trim()
            }

            # Associate variable with the most recent comment block
            $orderedResults += @{
                Type = "Variable"; 
                Name = $varName; 
                Value = $varValue; 
                Comment = $inlineComment; 
                Section = ($currentCommentBlock -join "`n");
                Line = $lineNumber
            }

            # Reset comment block after using it
            $currentCommentBlock = @()
            continue
        }

        # Preserve empty lines for readability
        if ($trimmedLine -eq "") {
            $orderedResults += @{ Type = "Empty"; Line = $lineNumber }
        }
    }

    # Output results while preserving order
    foreach ($entry in $orderedResults) {
        switch ($entry.Type) {
            "Comment" { Write-Output "`n$($entry.Value)" }
            "Variable" { Write-Output "Variable: $($entry.Name), Value: $($entry.Value) $($entry.Comment)" }
            "Empty" { Write-Output "" }
        }
    }
    
    return $orderedResults
}

# Main script logic

# Set default output folder path if not provided
if (-not $outputFolderPath) {
    $repoRoot = (Get-Location).Path
    $outputFolderPath = Join-Path -Path $repoRoot -ChildPath $DEFAULT_OUTPUT_FOLDER
    Write-Verbose "Output folder path not provided. Using default: $outputFolderPath"
}

# Ensure the output folder exists
if (-not (Test-Path -Path $outputFolderPath)) {
    New-Item -ItemType Directory -Path $outputFolderPath | Out-Null
    Write-Verbose "Created output folder: $outputFolderPath"
}

if (-not $pathArray -or $pathArray.Count -eq 0) {
    Write-Error "No paths provided to process."
    exit 1
}

# Check if the path is a file or a folder
Write-Verbose "Processing Files: $($pathArray -join ', ')"

foreach ($path in $pathArray) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Warning "Skipping empty path."
        continue
    }

    if (Test-Path $path) {
        if (Test-Path $path -PathType Leaf) {
            Write-Verbose "Processing file: $path"
            Invoke-ProcessScadFile -filePath $path -outputFolderPath $outputFolderPath
        } elseif (Test-Path $path -PathType Container) {
            Write-Verbose "Processing folder: $path"
            Invoke-ProcessScadFilesInFolder -folderPath $path -outputFolderPath $outputFolderPath
        } else {
            Write-Warning "The path is neither a valid file or a folder: $path"
        }
    } else {
        Write-Warning "The provided path does not exist: $path"
    }
}