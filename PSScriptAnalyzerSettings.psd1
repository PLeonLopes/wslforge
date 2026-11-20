@{
    # Rules for every .ps1 in the repository (used by the Lint workflow).
    ExcludeRules = @(
        # install.ps1 is an interactive installer: Write-Host is how it talks
        # to the user, with colors, and its output is not meant for a pipeline.
        'PSAvoidUsingWriteHost'
    )
}
