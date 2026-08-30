@{
    Schema = 'github-local-index.public-exposure-path-policy.v2'

    # These tokens identify the source-owned classification contract. This
    # path policy consumes no level and cannot grant a project restriction.
    ClassificationTokens = @(
        'public_personal_data_classification'
        'below_l3_publication_default'
        'project_publication_restriction_authority'
    )

    # Keep these expressions compatible with both PowerShell/.NET regex and grep -E.
    # PathRegex identifies candidates for publication review. It is not a hard
    # sensitivity classification and must not be used to uplift L1/L2.
    PathRegex = '(^|/)(99_private|raw|secrets?)(/|$)|(^|/)(\.env(\..*)?|[^/]+\.env(\..*)?)$|(^|/)[^/]*(private[_-]?key|client[_-]?secret)[^/]*$|(^|/)[^/]*auth[-_]?profiles[^/]*\.json$|(^|/)(logs?)(/|$)|\.(pem|key|p12|pfx|log|sqlite|db|wal|shm)$'
    # Keep only explicit private/secret/credential signals in this path-only
    # gate. Raw material and log/database extensions are review candidates.
    AlwaysBlockedPathRegex = '(^|/)(99_private|secrets?)(/|$)|(^|/)[^/]*(private[_-]?key|client[_-]?secret)[^/]*$|(^|/)[^/]*auth[-_]?profiles[^/]*\.json$|\.(pem|key|p12|pfx)$'
    ReviewCandidatePathRegex = '(^|/)(raw|logs?)(/|$)|\.(log|sqlite|db|wal|shm)$'
    EnvPathRegex = '(^|/)(\.env(\..*)?|[^/]+\.env(\..*)?)$'
    AllowedTemplateRegex = '(^|/)(\.env|[^/]+\.env)\.(example|sample|template|dist)$'

    GitIgnorePatterns = @(
        '99_private/'
        'secret/'
        'secrets/'
        '.env'
        '.env.*'
        '*.env'
        '*.env.*'
        '!.env.example'
        '!.env.sample'
        '!.env.template'
        '!.env.dist'
        '!*.env.example'
        '!*.env.sample'
        '!*.env.template'
        '!*.env.dist'
        '*.pem'
        '*.key'
        '*.p12'
        '*.pfx'
        '*private_key*'
        '*private-key*'
        '*client_secret*'
        '*client-secret*'
        '*auth-profiles*.json'
        '*auth_profiles*.json'
    )

    Cases = @(
        @{ Path = '.env'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/.env.local'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/.env.production'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/service.env'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/service.env.local'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/.env.example'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/.env.sample'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/.env.template'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/.env.dist'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/service.env.example'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/service.env.example.local'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'secrets/.env.example'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'raw/service.env.example'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/.envrc'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = 'nested/environment.md'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
        @{ Path = '99_private/fixture.txt'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'raw/fixture.txt'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'secret/fixture.txt'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'secrets/fixture.txt'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/private-key.txt'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/client_secret.json'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/auth-profiles.test.json'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/certificate.p12'; Blocked = $true; AlwaysBlocked = $true; ReviewCandidate = $false }
        @{ Path = 'nested/history.log'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/history.sqlite'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/history.db'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/history.wal'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/history.shm'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $true }
        @{ Path = 'nested/public-example.json'; Blocked = $false; AlwaysBlocked = $false; ReviewCandidate = $false }
    )
}
