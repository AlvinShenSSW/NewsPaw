# Sourced by archive.sh and upload.sh (RD22): the team, the authentication
# route and the mask applied to everything the scripts print. Expects ROOT and
# fail() from the script that sources it. Not executable on its own.
#
# The route is chosen by what exists on this Mac:
#   ~/.appstoreconnect/newspaw.env exists  -> the App Store Connect API key it names
#   it does not exist                      -> the Apple account signed in to Xcode
# The env file holds, besides blank lines and # comments, exactly:
#   ASC_KEY_ID=<10 capital letters or digits>
#   ASC_ISSUER_ID=<UUID>
#   ASC_KEY_PATH=<absolute path>   (optional; default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
# The key file is never read or printed here: only its path is passed to xcodebuild.
# Nothing in these lines prints an identifier; every output goes through mask.

SIGNING_LOCAL="$ROOT/ios/Config/Signing.local.xcconfig"
ASC_ENV="$HOME/.appstoreconnect/newspaw.env"

# The team of the local signing file: its only line that is neither blank nor a // comment.
local_team() {
  local lines
  lines=$(grep -vE '^[[:space:]]*(//.*)?$' "$SIGNING_LOCAL" || true)
  [ "$(printf '%s' "$lines" | grep -c '^')" = 1 ] || return 0
  printf '%s\n' "$lines" | sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p'
}

# Sets TEAM and the mask, or refuses.
read_team() {
  [ -f "$SIGNING_LOCAL" ] || fail "no ios/Config/Signing.local.xcconfig; write one line: DEVELOPMENT_TEAM = <your Team ID>"
  TEAM=$(local_team)
  [ -n "$TEAM" ] || fail "ios/Config/Signing.local.xcconfig must hold exactly one line besides blank and // comment lines: DEVELOPMENT_TEAM = <ten capital letters or digits>"
  MASK_ARGS=(-e "s/$TEAM/<team>/g" -e 's/"[A-Z0-9]{10}\./"<prefix>./g')
}

# One value of the env file's lines: the text after NAME=.
env_value() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# Sets ROUTE and AUTH_ARGS (empty for the Xcode account), or refuses. Call after read_team.
read_auth() {
  AUTH_ARGS=()
  ASC_KEY_ID=""
  ASC_ISSUER_ID=""
  ASC_KEY_PATH=""
  if [ ! -e "$ASC_ENV" ] && [ ! -L "$ASC_ENV" ]; then
    ROUTE="the Apple account signed in to Xcode (no ~/.appstoreconnect/newspaw.env)"
    return 0
  fi
  [ -f "$ASC_ENV" ] && [ ! -L "$ASC_ENV" ] || fail "~/.appstoreconnect/newspaw.env is not a regular file"
  local lines bad count name
  lines=$(grep -vE '^[[:space:]]*(#.*)?$' "$ASC_ENV" || true)
  bad=$(printf '%s\n' "$lines" | grep -vcE '^(ASC_KEY_ID=[A-Z0-9]{10}|ASC_ISSUER_ID=[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|ASC_KEY_PATH=/[^[:cntrl:]]*)$|^$' || true)
  [ "$bad" = 0 ] || fail "~/.appstoreconnect/newspaw.env may hold only ASC_KEY_ID=, ASC_ISSUER_ID=, ASC_KEY_PATH=<absolute path>, blank lines and # comments"
  for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    count=$(printf '%s\n' "$lines" | grep -c "^$name=" || true)
    [ "$count" -le 1 ] || fail "~/.appstoreconnect/newspaw.env names $name more than once"
  done
  ASC_KEY_ID=$(env_value ASC_KEY_ID "$lines")
  ASC_ISSUER_ID=$(env_value ASC_ISSUER_ID "$lines")
  ASC_KEY_PATH=$(env_value ASC_KEY_PATH "$lines")
  [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] || fail "~/.appstoreconnect/newspaw.env needs ASC_KEY_ID and ASC_ISSUER_ID"
  [ -n "$ASC_KEY_PATH" ] || ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  # The key's path is not printed: it carries the key ID.
  [ -e "$ASC_KEY_PATH" ] || [ -L "$ASC_KEY_PATH" ] || fail "the API key file named by ~/.appstoreconnect/newspaw.env does not exist"
  [ -f "$ASC_KEY_PATH" ] && [ ! -L "$ASC_KEY_PATH" ] || fail "the API key file is not a regular file"
  local mode
  mode=$(stat -f %Lp "$ASC_KEY_PATH")
  [ $(( 8#$mode & 8#044 )) = 0 ] || fail "the API key file is readable by group or others; make it chmod 600"
  local issuer_lower issuer_upper
  issuer_lower=$(printf '%s' "$ASC_ISSUER_ID" | tr 'A-F' 'a-f')
  issuer_upper=$(printf '%s' "$ASC_ISSUER_ID" | tr 'a-f' 'A-F')
  MASK_ARGS+=(-e "s/$ASC_KEY_ID/<key-id>/g" -e "s/$issuer_lower/<issuer-id>/g" -e "s/$issuer_upper/<issuer-id>/g")
  AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  ROUTE="an App Store Connect API key (~/.appstoreconnect/newspaw.env)"
}

# Everything printed goes through this: the team, the App ID prefix, the key ID and the issuer ID masked.
mask() { sed -E "${MASK_ARGS[@]}"; }
