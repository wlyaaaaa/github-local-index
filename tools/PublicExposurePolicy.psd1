@{
    Schema = 'github-local-index.public-exposure-path-policy.v1'

    # Keep these expressions compatible with both PowerShell/.NET regex and grep -E.
    PathRegex = '(^|/)(99_private|raw|secrets?)(/|$)|(^|/)(\.env(\..*)?|[^/]+\.env(\..*)?)$|(^|/)[^/]*(private[_-]?key|client[_-]?secret)[^/]*$|(^|/)[^/]*auth[-_]?profiles[^/]*\.json$|\.(pem|key|p12|pfx|log|sqlite|db|wal|shm)$'
    AlwaysBlockedPathRegex = '(^|/)(99_private|raw|secrets?)(/|$)|(^|/)[^/]*(private[_-]?key|client[_-]?secret)[^/]*$|(^|/)[^/]*auth[-_]?profiles[^/]*\.json$|\.(pem|key|p12|pfx|log|sqlite|db|wal|shm)$'
    EnvPathRegex = '(^|/)(\.env(\..*)?|[^/]+\.env(\..*)?)$'
    AllowedTemplateRegex = '(^|/)(\.env|[^/]+\.env)\.(example|sample|template|dist)$'

    GitIgnorePatterns = @(
        '99_private/'
        'raw/'
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
        '*.log'
        '*.sqlite'
        '*.db'
        '*.wal'
        '*.shm'
    )

    Cases = @(
        @{ Path = '.env'; Blocked = $true }
        @{ Path = 'nested/.env.local'; Blocked = $true }
        @{ Path = 'nested/.env.production'; Blocked = $true }
        @{ Path = 'nested/service.env'; Blocked = $true }
        @{ Path = 'nested/service.env.local'; Blocked = $true }
        @{ Path = 'nested/.env.example'; Blocked = $false }
        @{ Path = 'nested/.env.sample'; Blocked = $false }
        @{ Path = 'nested/.env.template'; Blocked = $false }
        @{ Path = 'nested/.env.dist'; Blocked = $false }
        @{ Path = 'nested/service.env.example'; Blocked = $false }
        @{ Path = 'nested/service.env.example.local'; Blocked = $true }
        @{ Path = 'secrets/.env.example'; Blocked = $true }
        @{ Path = 'raw/service.env.example'; Blocked = $true }
        @{ Path = 'nested/.envrc'; Blocked = $false }
        @{ Path = 'nested/environment.md'; Blocked = $false }
        @{ Path = 'raw/fixture.txt'; Blocked = $true }
        @{ Path = 'secret/fixture.txt'; Blocked = $true }
        @{ Path = 'secrets/fixture.txt'; Blocked = $true }
        @{ Path = 'nested/private-key.txt'; Blocked = $true }
        @{ Path = 'nested/client_secret.json'; Blocked = $true }
        @{ Path = 'nested/auth-profiles.test.json'; Blocked = $true }
        @{ Path = 'nested/certificate.p12'; Blocked = $true }
        @{ Path = 'nested/history.sqlite'; Blocked = $true }
        @{ Path = 'nested/public-example.json'; Blocked = $false }
    )
}
