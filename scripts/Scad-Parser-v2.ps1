# OpenSCAD Parser and Merger Script
# 
# This PowerShell script processes OpenSCAD (.scad) files by:
# - Parsing variables, functions, modules, comments, and customizer sections.
# - Handling `include` and `use` statements recursively, merging referenced files.
# - Maintaining whitespace and preserving original formatting.
# - Ensuring Customizer sections appear before modules and functions.
# - Removing duplicate Customizer sections, prioritizing those in the parent file.
# - Logging duplicated Customizer sections to the console.
# - Adding section markers for included files in the merged output.
#
# The output is a fully merged OpenSCAD file with all dependencies inlined,
# eliminating the need for `include` and `use` statements.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$pathArray,  # The input path (file or folder)

    [Parameter(Mandatory = $false)]
    [string]$outputFolderPath # Default to "output" folder in the same directory as the input file
)

$VerbosePreference = 'Continue'
$DEFAULT_OUTPUT_FOLDER = "output"

enum LogicType {
    Unknown
    Module
    Function
    Comment
    Customizer
    Variable
    Include
    Use
    Empty
}

class ScadFile {
    [string]$Path
    [string]$Content
    [string]$ExpandedContent
    [string]$Name
    [bool]$IsProcessed
    [System.Collections.Generic.List[ScadEntry]]$Entries
    [System.Collections.Generic.List[ScadFile]]$ImportedFiles
    [System.Collections.Generic.List[string]]$ImportsProcessed

    ScadFile() {
        $this.ImportedFiles = New-Object 'System.Collections.Generic.List[ScadFile]'
        $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
        $this.ImportsProcessed = New-Object 'System.Collections.Generic.List[string]'
    }

    ScadFile([string]$path, [string]$content) {
        $this.Path = $path
        $this.Content = $content
        $this.ExpandedContent = $content
        $this.Name = Split-Path $path -Leaf
        $this.IsProcessed = $false
        $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
        $this.ImportedFiles = New-Object 'System.Collections.Generic.List[ScadFile]'
        $this.ImportsProcessed = New-Object 'System.Collections.Generic.List[string]'
    }

    # Constructor with path and content
    # ScadFile([string]$path, [string]$content) {
    #     $this.Path = $path
    #     $this.Content = $content
    #     $this.ExpandedContent = $content
    #     $this.Name = Split-Path $path -Leaf
    #     $this.IsProcessed = $false
    #     $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
    #     $this.ImportedFiles = New-Object 'System.Collections.Generic.List[ScadFile]'
    # }
}

class ScadEntry {
    [LogicType]$Type    # "Comment", "Variable", "Include", "Use", "Function", "Module", "Customizer", or "Empty"
    [string]$Content    # Full text (for comments, functions, etc.)
    [string]$Value      # Variable value (only for variables)
    [string]$Section    # Associated comment block
    [int]$LineNumber    # Line number in the file
    [string]$LeadingWhitespace # Leading whitespace before the entry
    [string]$FileName   # File name the entry belongs to

    ScadEntry([LogicType]$type, [string]$content, [string]$value, [string]$section, [int]$line, [string]$whitespace = "", [string]$fileName = "") {
        $this.Type = $type
        $this.Content = $content
        $this.Value = $value
        $this.Section = $section
        $this.LineNumber = $line
        $this.LeadingWhitespace = $whitespace
        $this.FileName = $fileName
    }

    [string] ToString() {
        return "$($this.LeadingWhitespace)$($this.Content)"
    }
}

class ScadParser {
    [ScadFile]$scadFile
    [string[]]$Lines
    [System.Collections.Generic.List[ScadEntry]]$Entries
    [System.Collections.Generic.HashSet[string]]$ProcessedFiles
    [System.Collections.Generic.Dictionary[string, ScadEntry]]$CustomizerSections

    ScadParser([ScadFile]$scadFile) {
        $this.scadFile = $scadFile
        $this.Lines = $scadFile.Content -split "`r?`n"
        $this.Entries = $scadFile.Entries
        $this.ProcessedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
        $this.CustomizerSections = New-Object 'System.Collections.Generic.Dictionary[string, ScadEntry]'
    }

    [void] Parse() {
        # Skip parsing files that have already been processed
        if ($this.ProcessedFiles.Contains($this.Path)) { return }

        $this.ProcessedFiles.Add($this.scadFile.Path)

        $insideMultiLineComment = $false
        $multiLineCommentBuffer = ""
        $currentCommentBlock = @()
        $insideFunction = $false
        $insideModule = $false
        $insideCustomizer = $false
        $functionBuffer = ""
        $moduleBuffer = ""
        $customizerBuffer = ""
        $bracketCount = 0
        $customizerName = ""

        for ($i = 0; $i -lt $this.Lines.Length; $i++) {
            $line = $this.Lines[$i]
            $leadingWhitespace = $line -match '^(\s*)' ? $matches[1] : ""
            $trimmedLine = $line.Trim()
            $lineNumber = $i + 1

            # Capture customizer variables (before modules and functions)
            if ($trimmedLine -match '/\*\s*\[\s*(.*?)\s*\]\s*\*/') {
                $insideCustomizer = $true
                $customizerName = $trimmedLine -replace '/\*\s*\[\s*(.*?)\s*\]\s*\*/', '$1'
                $customizerName = $customizerName.Trim()
                $customizerBuffer = $trimmedLine
                continue
            }
            if ($insideCustomizer) {
                $customizerBuffer += "`n$line"
                if ($trimmedLine -match '^\s*$') {
                    $insideCustomizer = $false
                    if (-not $this.CustomizerSections.ContainsKey($customizerName)) {
                        $entry = [ScadEntry]::new([LogicType]::Customizer, $customizerBuffer, $customizerName, $customizerName, $lineNumber, "", $this.scadFile.Name)
                        $this.CustomizerSections[$customizerName] = $entry
                        $this.Entries.Add($entry)
                    } else {
                        Write-Host "Duplicate Customizer [$customizerName] ignored from $($this.scadFile.Name)"
                    }
                    $customizerBuffer = ""
                }
                continue
            }

            # Capture functions
            if ($insideFunction) {
                $functionBuffer += "`n" + $line
                $bracketCount += ([regex]::Matches($trimmedLine, '{')).Count
                $bracketCount -= ([regex]::Matches($trimmedLine, '}')).Count
                if ($bracketCount -eq 0) {
                    $this.Entries.Add([ScadEntry]::new([LogicType]::Function, $functionBuffer, "", "", $lineNumber, $leadingWhitespace, $this.scadFile.Name))
                    $insideFunction = $false
                }
                continue
            }
            if ($trimmedLine -match '^\s*function\s+([\w_]+)\s*\((.*?)\)\s*=') {
                $insideFunction = $true
                $bracketCount = 1
                $functionBuffer = $line
                continue
            }

            # Capture modules
            if ($insideModule) {
                $moduleBuffer += "`n" + $line
                $bracketCount += ([regex]::Matches($trimmedLine, '{')).Count
                $bracketCount -= ([regex]::Matches($trimmedLine, '}')).Count
                if ($bracketCount -eq 0) {
                    $this.Entries.Add([ScadEntry]::new([LogicType]::Module, $moduleBuffer, "", "", $lineNumber, $leadingWhitespace, $this.scadFile.Name))
                    $insideModule = $false
                }
                continue
            }
            if ($trimmedLine -match '^\s*module\s+([\w_]+)\s*\((.*?)\)\s*{?') {
                $insideModule = $true
                $bracketCount = 1
                $moduleBuffer = $line
                continue
            }

            # Capture include/use statements
            if ($trimmedLine -match '^\s*(include|use)\s*<(.*?)>') {
                $type = ($matches[1] -eq "include") ? [LogicType]::Include : [LogicType]::Use
                $this.Entries.Add([ScadEntry]::new($type, $matches[0], $matches[2], "", $lineNumber, $leadingWhitespace, $this.scadFile.Name))
                $this.MergeFile($matches[2], $type)
                continue
            }
        }
    }

    [void] MergeFile([string]$importName, [string]$importType) {
        # Check if the file has already been processed
        if ($this.ProcessedFiles.Contains($importName)) { return }

        # Resolve the absolute path
        $importPath = Resolve-Path -Path $importName -ErrorAction SilentlyContinue
        if (-not $importPath) {
            $importPath = Resolve-Path -Path (Join-Path -Path (Split-Path $this.scadFile.Path) -ChildPath $importName) -ErrorAction SilentlyContinue
        }
        
        if (-not $importPath) {
            Write-Warning "Failed to resolve path for file: $importName"
            return
        }

        # Read the file content
        $fileContent = Get-Content -Path $importPath.Path -Raw
        if (-not $fileContent) {
            Write-Warning "Failed to read content from file: $importPath"
            return
        }

        # Create ScadFile and parse it
        $importScadFile = New-Object ScadFile -ArgumentList $importPath.Path, $fileContent
        $importParser = [ScadParser]::new($importScadFile)
        $importParser.Parse()

        # Collect entries from the included file
        $importEntries = $importParser.Entries

        # Sort Entries to Place Customizer First and Remove Duplicates
        $customizerEntries = @()
        $otherEntries = @()
        $seenCustomizers = @{}

        foreach ($entry in $importEntries) {
            if ($entry.Type -eq [LogicType]::Customizer) {
                if (-not $seenCustomizers.ContainsKey($entry.Content)) {
                    $customizerEntries += $entry
                    $seenCustomizers[$entry.Content] = $true
                } else {
                    Write-Host "Duplicate Customizer section found: '$($entry.Content)' from $importName"
                }
            } else {
                $otherEntries += $entry
            }
        }

        # Add section header
        $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, "// === Begin content from $($importName) ===", "", "", 0, "", $this.scadFile.Name))

        # First add unique Customizer sections
        foreach ($entry in $customizerEntries) {
            $this.Entries.Insert(0, $entry)
        }

        # Then add all other content
        foreach ($entry in $otherEntries) {
            $this.Entries.Add($entry)
        }

        $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, "// === End content from $($importName) ===", "", "", 0, "", $this.scadFile.Name))

        # remove the import statement from the parent file will either be include or use
        $this.Entries = $this.Entries | Where-Object { !($_.Value -eq $importName -and $_.Type -eq $importType) }

        # Mark the file as processed
        $this.ProcessedFiles.Add($importPath)
        $this.scadFile.ImportedFiles.Add($importScadFile)
        $this.scadFile.ImportsProcessed.Add($importName)
    }

    [void] GenerateMergedContent() {
        $mergedContent = @()
        $importEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Include -or $_.Type -eq [LogicType]::Use }
        $moduleEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Module }
        $functionEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Function }
        $customizerEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Customizer }
        $commentEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Comment }
        $variableEntities = $this.Entries | Where-Object { $_.Type -eq [LogicType]::Variable }

        

        $this.scadFile.ExpandedContent = $mergedContent -join "`n"
    }
}


### Functions ###

function GenerateMergedContent{
    param(
        [ScadFile]$ScadFile,
        [String]$ParentFileName
    )

    $mergedContent = @()
    $importEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Include -or $_.Type -eq [LogicType]::Use } | Select-Object -Unique
    $moduleEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Module }
    $functionEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Function }
    $customizerEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Customizer }
    $commentEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Comment }
    $variableEntities = $ScadFile.Entries | Where-Object { $_.Type -eq [LogicType]::Variable }

    # Add the comment from the parent file that starts the file
    $parentComment = $commentEntities | Where-Object { $_.FileName -eq $ParentFileName } | Select-Object -First 1
    if ($parentComment) {
        $mergedContent += $parentComment.ToString()
    }

    # Add a comment indicating the file has been generated
    $generatedComment = [ScadEntry]::new([LogicType]::Comment, "// This file has been generated by an automated process for use on MakerWorld", "", "", 0, "", $ParentFileName)
    $mergedContent += $generatedComment.ToString()

    # Add import statements
    foreach ($entry in $importEntities) {
        # Add a comment indicating the source file for the import
        # $mergedContent += "// Import from file: $($entry.Value)"
        if ($ScadFile.ImportsProcessed -contains $entry.Value) {
            continue
        }
        $mergedContent += $entry.ToString()
    }

    $mergedContent += ""

    # Add customizer sections
    foreach ($entry in $customizerEntities) {
        # Add a comment indicating the source file for the customizer
        $mergedContent += "// Customizer from file: $($entry.FileName)"
        $mergedContent += $entry.ToString()
        $mergedContent += ""
    }

    # Add variable declarations
    foreach ($entry in $variableEntities) {
        # Add a comment indicating the source file for the variable
        $mergedContent += "// Variable from file: $($entry.FileName)"
        $mergedContent += $entry.ToString()
        $mergedContent += ""
    }

    # Add module definitions
    foreach ($entry in $moduleEntities) {
        # Add a comment indicating the source file for the module
        $mergedContent += "// Module from file: $($entry.FileName)"
        $mergedContent += $entry.ToString()
        $mergedContent += ""
    }

    # Add function definitions
    foreach ($entry in $functionEntities) {
        # Add a comment indicating the source file for the function
        $mergedContent += "// Function from file: $($entry.FileName)"
        $mergedContent += $entry.ToString()
        $mergedContent += ""
    }

    # $ScadFile.ExpandedContent = $mergedContent -join "`n"

    return $mergedContent -join "`n"

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
    # $scadContent = (Get-Content -Path $filePath -Raw) -split "`r?`n"
    $content = Get-Content -Path $filePath -Raw

    $scadFile = New-Object ScadFile -ArgumentList $fileDetails.FullName, $content

    # Load OpenSCAD file and parse it
    $parser = [ScadParser]::new($scadFile)
    $parser.Parse()

    # Print parsed results
    # $parser.PrintResults()

    # Collect all entries
    $allEntries = @()
    $allEntries += $parser.Entries

    # Merge the content
    $mergedContent = GenerateMergedContent -ScadFile $scadFile -ParentFileName $fileDetails.Name



    # Write the parsed content to a new file
    $outputFilePath = Join-Path -Path $outputFolderPath -ChildPath $fileDetails.Name
    # $allEntries | ForEach-Object { $_.ToString() } | Set-Content -Path $outputFilePath
    $mergedContent | Set-Content -Path $outputFilePath
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