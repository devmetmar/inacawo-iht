# API credentials (via `setup_env.bash` only)

Helpers: `src/setup_credentials.bash` + templates here. **Do not run them alone** —
always:

```bash
source $HOME/inacawo-iht/setup_env.bash
```

Training uses **personal** CDS + Copernicus Marine accounts (not a shared Vault key).

## Pass credentials on setup (recommended for training)

```bash
source $HOME/inacawo-iht/setup_env.bash \
  --cds-key 'UID:YOUR_CDS_API_KEY' \
  --cmems-user 'your_cmems_username' \
  --cmems-pass 'your_cmems_password'
```

Optional: `--cds-url https://cds.climate.copernicus.eu/api`  
This **writes** `~/.cdsapirc` and `~/.copernicusmarine/.copernicusmarine-credentials`.

## Automatic dummy bootstrap

If those files are missing and you did not pass CLI args, iht seeds **dummy**
placeholders (marker `IHT_DUMMY_CREDENTIAL`) from:

| File | Template |
|------|----------|
| `~/.cdsapirc` | `src/credentials/cdsapirc.dummy` |
| `~/.copernicusmarine/.copernicusmarine-credentials` | `src/credentials/cmems-credentials.dummy.json` |

Existing files are **not** overwritten by dummy seed. CLI args **do** overwrite.
Disable seeding: `IHT_SKIP_CRED_BOOTSTRAP=1`.

Status at end of `setup_env`:

- **INFO** — both look real → ready for download  
- **WARNING** — still dummy / incomplete

## Manual edit / login alternatives

```bash
nano ~/.cdsapirc
copernicusmarine login
```

## Vault (operators only, opt-in)

```bash
export IHT_VAULT_CREDS=1
cp $HOME/inacawo-iht/src/credentials/vault-token.example \
   $HOME/inacawo-iht/src/credentials/vault-token
chmod 600 $HOME/inacawo-iht/src/credentials/vault-token
# paste real token into vault-token
source $HOME/inacawo-iht/setup_env.bash
```

See `src/credentials/vault-token.example` and `src/setup_vault.bash`.
