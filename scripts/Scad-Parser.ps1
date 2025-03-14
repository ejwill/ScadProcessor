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
    # [Import[]]$Imports
    # [Logic[]]$Logic

    # Default constructor
    ScadFile() {}

    # Constructor with path and content
    ScadFile([string]$path, [string]$content) {
        $this.Path = $path
        $this.Content = $content
        $this.ExpandedContent = $content
        $this.Name = Split-Path $path -Leaf
        $this.IsProcessed = $false
        $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
        # $this.Imports = @()
        # $this.Logic = @()
    }
}

class ScadEntry {
    [LogicType]$Type       # "Comment", "Variable", "Include", "Use", "Function", "Module", "Customizer", or "Empty"
    [string]$Content    # Full text (for comments, functions, etc.)
    [string]$Value      # Variable value (only for variables)
    [string]$Section    # Associated comment block
    [int]$LineNumber    # Line number in the file
    [string]$LeadingWhitespace

    ScadEntry([LogicType]$type, [string]$content, [string]$value, [string]$section, [int]$line, [string]$whitespace) {
        $this.Type = $type
        $this.Content = $content
        $this.Value = $value
        $this.Section = $section
        $this.LineNumber = $line
        $this.LeadingWhitespace = $whitespace
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

    ScadParser([ScadFile]$scadFile) {
        $this.scadFile = $scadFile
        $this.Lines = $scadFile.Content -split "`r?`n"
        $this.Entries = New-Object 'System.Collections.Generic.List[ScadEntry]'
        $this.ProcessedFiles = New-Object 'System.Collections.Generic.HashSet[System.String]'
    }

    [void] Parse([ScadFile]$scadFile) {
        # Skip parsing files that have already been processed
        if ($this.ProcessedFiles.Contains($scadFile.Path)) { return }

        $this.ProcessedFiles.Add($scadFile.Path)
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

            # Capture include/use statements
            if ($trimmedLine -match '^\s*(include|use)\s*<(.*?)>') {
                $type = ($matches[1] -eq "include") ? [LogicType]::Include : [LogicType]::Use
                $this.Entries.Add([ScadEntry]::new($type, $matches[2], "", "", $lineNumber, $leadingWhitespace))
                $this.scadFile.Entries.Add([ScadEntry]::new($type, $matches[2], "", "", $lineNumber, $leadingWhitespace))
                $this.MergeFile($matches[2])
                continue
            }

            # Capture customizer variables (before modules and functions)
            if ($trimmedLine -match '/\*\s*\[\s*(.*?)\s*\]\s*\*/') {
                $insideCustomizer = $true
                $customizerName = $trimmedLine -replace '/\*\s*\[\s*(.*?)\s*\]\s*\*/', '$1'
                $customizerName = $customizerName.Trim()
                $customizerBuffer = "$trimmedLine"
                continue
            }
            if ($insideCustomizer) {
                $customizerBuffer += "`n$line"
                if ($trimmedLine -match '\*/$') { 
                    $insideCustomizer = $false
                    if (-not $this.CustomizerSections.ContainsKey($customizerName)) {
                        $entry = [ScadEntry]::new([LogicType]::Customizer, $customizerBuffer, $customizerName, $customizerName, $lineNumber, "")
                        $this.CustomizerSections[$customizerName] = $entry
                        $this.Entries.Add($entry)
                    } else {
                        Write-Host "Duplicate Customizer [$customizerName] ignored from $($scadFile.Name)"
                    }
                    $customizerBuffer = ""
                }
                continue
            }

            # Capture multi-line comments
            if ($trimmedLine -match '^/\*') { 
                $insideMultiLineComment = $true
                $multiLineCommentBuffer = "$line"
                continue
            }
            if ($insideMultiLineComment) {
                $multiLineCommentBuffer += "`n$line"
                if ($trimmedLine -match '\*/$') { 
                    $insideMultiLineComment = $false
                    $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, $multiLineCommentBuffer, "", "", $lineNumber, $leadingWhitespace))
                }
                continue
            }

            # Capture single-line comments
            if ($trimmedLine -match '^//') {
                $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, $trimmedLine, "", "", $lineNumber, $leadingWhitespace))
                continue
            }

            # Capture functions
            if ($insideFunction) {
                $functionBuffer += "`n" + $line
                $bracketCount += ([regex]::Matches($trimmedLine, '{')).Count
                $bracketCount -= ([regex]::Matches($trimmedLine, '}')).Count
                if ($bracketCount -eq 0) {
                    $this.Entries.Add([ScadEntry]::new([LogicType]::Function, $functionBuffer, "", "", $lineNumber, $leadingWhitespace))
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
                    $this.Entries.Add([ScadEntry]::new([LogicType]::Module, $moduleBuffer, "", "", $lineNumber, $leadingWhitespace))
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

            # Capture variable assignments
            if ($trimmedLine -match '^([\w_]+)\s*=\s*([^;]+);') {
                $varName = $matches[1].Trim()
                $varValue = $matches[2].Trim()
                $this.Entries.Add([ScadEntry]::new([LogicType]::Variable, $varName, $varValue, "", $lineNumber, $leadingWhitespace))
                continue
            }

            # Capture empty lines
            if ($trimmedLine -eq "") {
                $this.Entries.Add([ScadEntry]::new([LogicType]::Empty, "", "", "", $lineNumber, $leadingWhitespace))
            }
        }
    }

    [void] MergeFile([string]$file) {
        # Check if the file has already been processed
        if ($this.ProcessedFiles.Contains($file)) { return }
    
        # Resolve the absolute path
        $absolutePath = Resolve-Path -Path $file -ErrorAction SilentlyContinue
        if (-not $absolutePath) {
            $absolutePath = Resolve-Path -Path (Join-Path -Path (Split-Path $this.scadFile.Path) -ChildPath $file) -ErrorAction SilentlyContinue
        }
        
        if (-not $absolutePath) {
            Write-Warning "Failed to resolve path for file: $file"
            return
        }
    
        # Read the file content
        $fileContent = Get-Content -Path $absolutePath.Path -Raw
        if (-not $fileContent) {
            Write-Warning "Failed to read content from file: $absolutePath"
            return
        }
    
        # Mark file as processed
        $this.ProcessedFiles.Add($absolutePath.Path)
    
        # Create ScadFile and parse it
        $importScadFile = New-Object ScadFile -ArgumentList $absolutePath.Path, $fileContent
        $fileParser = [ScadParser]::new($importScadFile)
        $fileParser.Parse($importScadFile)
    
        # Collect entries from the included file
        $includedEntries = $fileParser.Entries

        # Sort Entries to Place Customizer First and Remove Duplicates
        $customizerEntries = @()
        $otherEntries = @()
        $seenCustomizers = @{}

        foreach ($entry in $includedEntries) {
            if ($entry.Type -eq [LogicType]::Customizer) {
                if (-not $seenCustomizers.ContainsKey($entry.Content)) {
                    $customizerEntries += $entry
                    $seenCustomizers[$entry.Content] = $true
                } else {
                    Write-Host "Duplicate Customizer section found: '$($entry.Content)' from $file"
                }
            } else {
                $otherEntries += $entry
            }
        }

        # Add section header
        $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, "// === Begin content from $($absolutePath) ===", "", "", 0))

        # First add unique Customizer sections
        foreach ($entry in $customizerEntries) {
            $this.Entries.Add($entry)
        }

        # Then add all other content
        foreach ($entry in $otherEntries) {
            $this.Entries.Add($entry)
        }
    
        # # Sort Entries to Place Customizer First
        # $customizerEntries = $includedEntries | Where-Object { $_.Type -eq [LogicType]::Customizer }
        # $otherEntries = $includedEntries | Where-Object { $_.Type -ne [LogicType]::Customizer }
    
        # # Add section header
        # $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, "// === Begin content from $($absolutePath.Path) ===", "", "", 0))
    
        # # First add Customizer sections
        # foreach ($entry in $customizerEntries) {
        #     $this.Entries.Add($entry)
        # }
    
        # # Then add all other content
        # foreach ($entry in $otherEntries) {
        #     $this.Entries.Add($entry)
        # }
    
        # Add section footer
        $this.Entries.Add([ScadEntry]::new([LogicType]::Comment, "// === End content from $($absolutePath) ===", "", "", 0))
    }

    # [void] MergeFile([string]$file) {
    #     # Check if the file has already been processed
    #     if ($this.ProcessedFiles.Contains($file)) { return }

    #     # Load and parse the file
    #     $this.ProcessedFiles.Add($file)
    #     $absolutePath = Resolve-Path -Path $file -ErrorAction SilentlyContinue

    #     # Handle relative paths
    #     if (-not $absolutePath) {
    #         # $basePath = Split-Path -Path $file -Parent
    #         # $relativePath = Join-Path -Path (Get-Location) -ChildPath $basePath
    #         # $absolutePath = Resolve-Path -Path $relativePath -ErrorAction SilentlyContinue

    #         $absolutePath = Resolve-Path -Path (Join-Path -Path (Split-Path $this.scadFile.Path) -ChildPath $file) -ErrorAction SilentlyContinue
    #     }

    #     if (-not $absolutePath) {
    #         Write-Warning "Failed to resolve path for file: $file"
    #         return
    #     }

    #     $fileContent = Get-Content -Path $absolutePath.Path -Raw
    #     if (-not $fileContent) {
    #         Write-Warning "Failed to read content from file: $absolutePath"
    #         return
    #     }
    #     $importScadFile = New-Object ScadFile -ArgumentList $absolutePath.Path, $fileContent

    #     $fileParser = [ScadParser]::new($importScadFile)
    #     $fileParser.Parse($importScadFile)
        
    #     # Merge the file content into the main file content
    #     foreach ($entry in $fileParser.Entries) {
    #         $this.Entries.Add($entry)
    #     }
    # }

    [void] PrintResults() {
        Write-Host "`n=== Parsed OpenSCAD File ==="
        foreach ($entry in $this.Entries) { Write-Output $entry.ToString() }
    }

    [string] MergeFiles([string[]]$includedFiles) {
        $mergedContent = ""
        foreach ($file in $includedFiles) {
            $mergedContent += "`n// === Begin content from $file ===`n"
            $mergedContent += Get-Content -Path $file
            $mergedContent += "`n// === End content from $file ===`n"
        }
        return $mergedContent
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
    # $scadContent = (Get-Content -Path $filePath -Raw) -split "`r?`n"
    $content = Get-Content -Path $filePath -Raw

    $scadFile = New-Object ScadFile -ArgumentList $fileDetails.FullName, $content

    # Load OpenSCAD file and parse it
    $parser = [ScadParser]::new($scadFile)
    $parser.Parse($scadFile)

    # Print parsed results
    $parser.PrintResults()

    # Write the parsed content to a new file
    $outputFilePath = Join-Path -Path $outputFolderPath -ChildPath $fileDetails.Name
    $parser.Entries | ForEach-Object { $_.Content } | Set-Content -Path $outputFilePath

    # $scadFile = New-Object ScadFile -ArgumentList $fileDetails.FullName, $fileContent

    # if (-not $scadFile) {
    #     Write-Error "Failed to create ScadFile object for file: $filePath"
    #     return
    # }

    # Analyze the file content to extract imports, logic, and variables
    # $scadFile = Invoke-ParseScadFile -scadFile $scadFile
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